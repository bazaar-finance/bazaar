// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {CollateralLib} from "../../src/libraries/CollateralLib.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {OrderView} from "../OrderView.sol";
import {OrderManagementLib} from "../../src/libraries/OrderManagementLib.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythSeed} from "../PythSeed.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {BucketStore} from "../BucketStore.sol";

contract BazaarPairTest is Test {
    using stdStorage for StdStorage;
    StdStorage internal _stdstore;
    // Pyth feed IDs
    bytes32 constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant AAPL_USD_FEED_ID = 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688;

    // Scale constants
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant USDC_SCALE = 1e6;

    // Amounts
    uint256 constant INITIAL_USER_BALANCE = 100_000 * USDC_SCALE;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;

    // Derived from factory constants
    uint256 bondUsdc;
    uint256 seedUsdc;

    // Core contracts
    BazaarFactory public factory;
    BazaarOracle public oracle;
    BazaarPairTerminator public pairTerminator;

    // Deployed pairs
    BazaarPair public btcPair; // BTC/USD — continuously traded (24/7)
    BazaarPair public aaplPair; // AAPL/USD — not continuously traded (has trading hours)

    // Mocks
    MockUSDC public usdc;
    MockOptimisticOracleV3 public mockOOv3;
    MockPyth public mockPyth;

    // Test accounts (with private keys for meta-tx signing)
    uint256 constant USER1_PK = 0xA11CE;
    uint256 constant USER2_PK = 0xB0B;
    address public user1;
    address public user2;
    address public relayer;
    address public bugBountyAddress;

    function setUp() public {
        user1 = vm.addr(USER1_PK);
        user2 = vm.addr(USER2_PK);
        relayer = makeAddr("relayer");
        bugBountyAddress = makeAddr("bugBounty");

        // Deploy MockArbSys at the Arbitrum ArbSys precompile address (0x64)
        // so that _l2Block() works in Foundry tests
        vm.etch(address(0x64), address(new MockArbSys()).code);

        // Deploy factory via deployment script
        DeployBazaar deployer = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = deployer.deploy(bugBountyAddress);

        // Read addresses from config
        (, address usdcContract, address optimisticOracleV3,) = helperConfig.activeNetworkConfig();

        usdc = MockUSDC(usdcContract);
        mockOOv3 = MockOptimisticOracleV3(optimisticOracleV3);

        // Store sub-contract references
        oracle = factory.oracle();
        pairTerminator = factory.pairTerminator();
        mockPyth = MockPyth(address(oracle.pyth()));
        // The factory lists a raw feed only once Pyth has stored a price for it.
        PythSeed.seed(address(mockPyth), BTC_USD_FEED_ID);
        PythSeed.seed(address(mockPyth), AAPL_USD_FEED_ID);

        // Derive constants from factory
        bondUsdc = factory.DEPLOYMENT_BOND_USDC();
        seedUsdc = PROPOSAL_TOTAL_USDC - bondUsdc;

        // Mint USDC to test accounts
        usdc.mint(user1, INITIAL_USER_BALANCE);
        usdc.mint(user2, INITIAL_USER_BALANCE);

        // --- Deploy BTC/USD pair (continuously traded) ---
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 btcAssertionId = factory.proposePairDeployment(BTC_USD_FEED_ID, true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(btcAssertionId);

        (,,,,,, bytes32 btcPairId,,,) = factory.deploymentProposals(btcAssertionId);
        btcPair = BazaarPair(payable(factory.getPairAddress(btcPairId)));

        // --- Deploy AAPL/USD pair (not continuously traded) ---
        vm.startPrank(user2);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 aaplAssertionId =
            factory.proposePairDeployment(AAPL_USD_FEED_ID, false, PROPOSAL_TOTAL, "AAPL on NASDAQ");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(aaplAssertionId);

        (,,,,,, bytes32 aaplPairId,,,) = factory.deploymentProposals(aaplAssertionId);
        aaplPair = BazaarPair(payable(factory.getPairAddress(aaplPairId)));
    }

    // ==================== Setup Verification ====================

    function testSetup_BtcPairInitializedCorrectly() public view {
        assertEq(btcPair.baseFeedId(), BTC_USD_FEED_ID);
        assertTrue(btcPair.isContinuouslyTraded());
        assertEq(address(btcPair.usdc()), address(usdc));
        assertEq(address(btcPair.oracle()), address(oracle));
        assertEq(btcPair.auxState().bugBountyAddress, bugBountyAddress);
    }

    function testSetup_AaplPairInitializedCorrectly() public view {
        assertEq(aaplPair.baseFeedId(), AAPL_USD_FEED_ID);
        assertFalse(aaplPair.isContinuouslyTraded());
        assertEq(address(aaplPair.usdc()), address(usdc));
        assertEq(address(aaplPair.oracle()), address(oracle));
        assertEq(aaplPair.auxState().bugBountyAddress, bugBountyAddress);
    }

    function testSetup_BothPairsRegistered() public view {
        assertEq(factory.pairsCount(), 2);
        assertTrue(factory.isPair(address(btcPair)));
        assertTrue(factory.isPair(address(aaplPair)));
        assertTrue(address(btcPair) != address(aaplPair));
    }

    function testSetup_PairsHaveSeedFunds() public view {
        assertEq(usdc.balanceOf(address(btcPair)), seedUsdc);
        assertEq(usdc.balanceOf(address(aaplPair)), seedUsdc);
    }

    function testSetup_DeployerHasInsuranceShares() public view {
        uint256 seedBazaar = PROPOSAL_TOTAL - (bondUsdc * BAZAAR_SCALE / USDC_SCALE);

        // BTC pair — deployer is user1
        assertEq(btcPair.insuranceShares(user1), seedBazaar);
        assertEq(btcPair.totalInsuranceShares(), seedBazaar);

        // AAPL pair — deployer is user2
        assertEq(aaplPair.insuranceShares(user2), seedBazaar);
        assertEq(aaplPair.totalInsuranceShares(), seedBazaar);
    }

    function testSetup_InsuranceFundBalanceMatchesSeed() public view {
        uint256 seedBazaar = PROPOSAL_TOTAL - (bondUsdc * BAZAAR_SCALE / USDC_SCALE);

        (,,,,, uint256 btcInsuranceBal,,,,,,,,) = btcPair.pairVault();
        assertEq(btcInsuranceBal, seedBazaar);

        (,,,,, uint256 aaplInsuranceBal,,,,,,,,) = aaplPair.pairVault();
        assertEq(aaplInsuranceBal, seedBazaar);
    }

    // ==================== Helper: EIP-712 Signing ====================

    function _signDepositCollateral(
        BazaarPair pair,
        uint256 privateKey,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(MetaTxLib.DEPOSIT_COLLATERAL_TYPEHASH, amount, nonce, deadline, relayerFee)
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(pair.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ==================== depositCollateral Tests ====================

    function testDepositCollateral_DirectCall() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE; // 100 USDC
        uint256 depositUsdc = 100 * USDC_SCALE;

        vm.startPrank(user1);
        usdc.approve(address(btcPair), depositUsdc);

        vm.expectEmit(true, true, false, true, address(btcPair));
        emit BazaarTypes.CollateralDeposited(btcPair.pairId(), user1, depositAmount);
        btcPair.depositCollateral(depositAmount, 0, 0, 0, "", "");
        vm.stopPrank();

        // Verify collateral recorded in position bucket
        (,,, uint256 collateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(collateral, depositAmount);

        // Verify vault totalCollateralDeposited updated
        (,,,, uint256 totalCollateral,,,,,,,,,) = btcPair.pairVault();
        assertEq(totalCollateral, depositAmount);

        // Verify USDC transferred from user to pair
        // user1 started with INITIAL_USER_BALANCE, paid PROPOSAL_TOTAL_USDC for proposal, got bondUsdc back on settlement
        uint256 user1BalanceAfterSetup = INITIAL_USER_BALANCE - PROPOSAL_TOTAL_USDC + bondUsdc;
        assertEq(usdc.balanceOf(user1), user1BalanceAfterSetup - depositUsdc);
        assertEq(usdc.balanceOf(address(btcPair)), seedUsdc + depositUsdc);
    }

    function testDepositCollateral_ViaRelayer() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        uint256 relayerFeeAmount = 5e16; // 0.05 USDC in BAZAAR_SCALE
        uint256 relayerFeeUsdc = relayerFeeAmount * USDC_SCALE / BAZAAR_SCALE; // convert fee to USDC decimals
        uint256 totalPullUsdc = 100 * USDC_SCALE + relayerFeeUsdc; // deposit + relayer fee in USDC
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 10 seconds;

        // User approves pair to pull deposit + relayer fee
        vm.prank(user1);
        usdc.approve(address(btcPair), totalPullUsdc);

        // Sign meta-tx
        bytes memory sig = _signDepositCollateral(btcPair, USER1_PK, depositAmount, nonce, deadline, relayerFeeAmount);

        // Relayer submits — expect both CollateralDeposited and MetaTransactionExecuted
        vm.expectEmit(true, true, false, true, address(btcPair));
        emit BazaarTypes.CollateralDeposited(btcPair.pairId(), user1, depositAmount);
        vm.expectEmit(true, true, true, true, address(btcPair));
        emit BazaarTypes.MetaTransactionExecuted(
            btcPair.pairId(), user1, relayer, MetaTxLib.DEPOSIT_COLLATERAL_TYPEHASH, nonce, relayerFeeAmount
        );
        vm.prank(relayer);
        btcPair.depositCollateral(depositAmount, nonce, deadline, relayerFeeAmount, sig, "");

        // Verify collateral recorded for user (not relayer)
        (,,, uint256 collateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(collateral, depositAmount);

        // The fee accrued to the relayer's claimable balance; claiming pays it out in USDC
        (uint256 owed,) = btcPair.claimableFees(relayer);
        assertEq(owed, relayerFeeAmount);
        vm.prank(relayer);
        btcPair.claimFees();
        assertEq(usdc.balanceOf(relayer), relayerFeeUsdc);

        // Verify nonce incremented
        assertEq(btcPair.metaTxNonces(user1), 1);
    }

    function testDepositCollateral_ViaRelayerWithPermit() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        uint256 relayerFeeAmount = 5e16; // 0.05 USDC in BAZAAR_SCALE
        uint256 totalPullUsdc = 100 * USDC_SCALE + (relayerFeeAmount * USDC_SCALE / BAZAAR_SCALE);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 10 seconds;

        // Sign the deposit meta-tx (off-chain, free)
        bytes memory depositSig =
            _signDepositCollateral(btcPair, USER1_PK, depositAmount, nonce, deadline, relayerFeeAmount);

        // Sign ERC-2612 permit (off-chain, free) — no on-chain approve needed
        uint256 permitDeadline = block.timestamp + 30 seconds;
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 usdcDomainSeparator = usdc.DOMAIN_SEPARATOR();
        uint256 permitNonce = usdc.nonces(user1);

        bytes32 permitStructHash =
            keccak256(abi.encode(permitTypehash, user1, address(btcPair), totalPullUsdc, permitNonce, permitDeadline));
        bytes32 permitDigest = MessageHashUtils.toTypedDataHash(usdcDomainSeparator, permitStructHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER1_PK, permitDigest);

        bytes memory permitData = abi.encode(totalPullUsdc, permitDeadline, v, r, s);

        // Relayer submits — user never sent any on-chain transaction
        vm.expectEmit(true, true, false, true, address(btcPair));
        emit BazaarTypes.CollateralDeposited(btcPair.pairId(), user1, depositAmount);
        vm.prank(relayer);
        btcPair.depositCollateral(depositAmount, nonce, deadline, relayerFeeAmount, depositSig, permitData);

        // Verify collateral recorded for user
        (,,, uint256 collateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(collateral, depositAmount);

        // Verify the fee accrued to the relayer
        (uint256 owed,) = btcPair.claimableFees(relayer);
        assertEq(owed, relayerFeeAmount);

        // Verify user never called approve — allowance was set via permit
        // (permit sets exact allowance which gets consumed by transferFrom, so remaining should be 0)
        assertEq(usdc.allowance(user1, address(btcPair)), 0);
    }

    function testDepositCollateral_MultipleDeposits() public {
        uint256 firstDeposit = 50 * BAZAAR_SCALE;
        uint256 secondDeposit = 75 * BAZAAR_SCALE;
        uint256 firstUsdc = 50 * USDC_SCALE;
        uint256 secondUsdc = 75 * USDC_SCALE;

        vm.startPrank(user1);
        usdc.approve(address(btcPair), firstUsdc + secondUsdc);

        btcPair.depositCollateral(firstDeposit, 0, 0, 0, "", "");
        btcPair.depositCollateral(secondDeposit, 0, 0, 0, "", "");
        vm.stopPrank();

        // Verify collateral is cumulative
        (,,, uint256 collateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(collateral, firstDeposit + secondDeposit);
    }

    function testDepositCollateral_RevertsBelowMinimum() public {
        uint256 tooSmall = BAZAAR_SCALE / 2; // 0.5 USDC — below the 5 USDC minimum

        vm.startPrank(user1);
        usdc.approve(address(btcPair), USDC_SCALE);

        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralLib.CollateralLib__InvalidDepositAmount.selector, tooSmall, 5 * BAZAAR_SCALE
            )
        );
        btcPair.depositCollateral(tooSmall, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    function testDepositCollateral_RevertsInsufficientAllowance() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;

        vm.startPrank(user1);
        // No approval
        vm.expectRevert();
        btcPair.depositCollateral(depositAmount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    function testDepositCollateral_RevertsInsufficientBalance() public {
        address broke = makeAddr("broke");
        uint256 depositAmount = 100 * BAZAAR_SCALE;

        vm.startPrank(broke);
        usdc.approve(address(btcPair), 100 * USDC_SCALE);

        vm.expectRevert();
        btcPair.depositCollateral(depositAmount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    function testDepositCollateral_RelayerRevertsExpiredDeadline() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 10 seconds;

        bytes memory sig = _signDepositCollateral(btcPair, USER1_PK, depositAmount, nonce, deadline, 0);

        // Warp past deadline
        vm.warp(deadline + 1);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(MetaTxLib.MetaTx__ExpiredDeadline.selector, deadline, block.timestamp));
        btcPair.depositCollateral(depositAmount, nonce, deadline, 0, sig, "");
    }

    function testDepositCollateral_RelayerRevertsWrongNonce() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        uint256 wrongNonce = 5;
        uint256 deadline = block.timestamp + 10 seconds;

        bytes memory sig = _signDepositCollateral(btcPair, USER1_PK, depositAmount, wrongNonce, deadline, 0);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(MetaTxLib.MetaTx__InvalidNonce.selector, 0, wrongNonce));
        btcPair.depositCollateral(depositAmount, wrongNonce, deadline, 0, sig, "");
    }

    function testDepositCollateral_RelayerRevertsExcessiveFee() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        uint256 excessiveFee = 2 * BAZAAR_SCALE; // 2 USDC — exceeds MAX_RELAYER_FEE (1 USDC)
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 10 seconds;

        bytes memory sig = _signDepositCollateral(btcPair, USER1_PK, depositAmount, nonce, deadline, excessiveFee);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                MetaTxLib.MetaTx__RelayerFeeExceedsMax.selector, excessiveFee, MetaTxLib.MAX_RELAYER_FEE
            )
        );
        btcPair.depositCollateral(depositAmount, nonce, deadline, excessiveFee, sig, "");
    }

    function testDepositCollateral_RelayerRevertsRelayerFeeGteAmount() public {
        uint256 depositAmount = 1 * BAZAAR_SCALE;
        uint256 relayerFeeAmount = 1 * BAZAAR_SCALE; // fee == amount
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 10 seconds;

        bytes memory sig = _signDepositCollateral(btcPair, USER1_PK, depositAmount, nonce, deadline, relayerFeeAmount);

        vm.prank(relayer);
        vm.expectRevert(BazaarPair.BazaarPair__RelayerFeeExceedsDeposit.selector);
        btcPair.depositCollateral(depositAmount, nonce, deadline, relayerFeeAmount, sig, "");
    }

    function testDepositCollateral_RelayerRevertsInvalidSignature() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 10 seconds;

        // Sign with wrong private key
        uint256 WRONG_PK = 0xDEAD;
        bytes memory badSig = _signDepositCollateral(btcPair, WRONG_PK, depositAmount, nonce, deadline, 0);

        vm.prank(relayer);
        // Will recover a different signer whose nonce != 0 expected
        vm.expectRevert();
        btcPair.depositCollateral(depositAmount, nonce, deadline, 0, badSig, "");
    }

    function testDepositCollateral_RevertsDeadlineTooFar() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 60 seconds; // exceeds the 10s max window

        bytes memory sig = _signDepositCollateral(btcPair, USER1_PK, depositAmount, nonce, deadline, 0);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(MetaTxLib.MetaTx__DeadlineTooFar.selector, deadline, block.timestamp + 10 seconds)
        );
        btcPair.depositCollateral(depositAmount, nonce, deadline, 0, sig, "");
    }

    function testDepositCollateral_WorksOnBothPairs() public {
        uint256 depositAmount = 50 * BAZAAR_SCALE;
        uint256 depositUsdc = 50 * USDC_SCALE;

        // user1 deposits into BTC pair
        vm.startPrank(user1);
        usdc.approve(address(btcPair), depositUsdc);
        btcPair.depositCollateral(depositAmount, 0, 0, 0, "", "");
        vm.stopPrank();

        // user2 deposits into AAPL pair
        vm.startPrank(user2);
        usdc.approve(address(aaplPair), depositUsdc);
        aaplPair.depositCollateral(depositAmount, 0, 0, 0, "", "");
        vm.stopPrank();

        // Verify both pairs have correct collateral
        (,,, uint256 btcCollateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(btcCollateral, depositAmount);

        (,,, uint256 aaplCollateral,,,,,) = aaplPair.positionBuckets(user2);
        assertEq(aaplCollateral, depositAmount);
    }

    // ==================== Helper: EIP-712 Signing (Withdraw) ====================

    function _signWithdrawCollateral(
        BazaarPair pair,
        uint256 privateKey,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(MetaTxLib.WITHDRAW_COLLATERAL_TYPEHASH, amount, nonce, deadline, relayerFee)
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(pair.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ==================== Helper: Deposit Collateral ====================

    function _depositCollateral(BazaarPair pair, address user, uint256 amount) internal {
        uint256 amountUsdc = amount * USDC_SCALE / BAZAAR_SCALE;
        vm.startPrank(user);
        usdc.approve(address(pair), amountUsdc);
        pair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @notice Claim #4: a deposit credits only the µUSDC-aligned amount, so bookkeeping never
    ///         exceeds the USDC actually pulled. A sub-µUSDC remainder is dropped, not over-credited.
    function test_DepositCollateral_RoundsToUsdcGranularity() public {
        uint256 raw = 100 * BAZAAR_SCALE + 5e11; // $100 + 0.0000005 USDC (sub-µUSDC remainder)
        uint256 expected = raw - (raw % 1e12); // = exactly 100e18

        (,,,, uint256 collBefore,,,,,,,,,) = btcPair.pairVault();
        uint256 pairUsdcBefore = usdc.balanceOf(address(btcPair));

        _depositCollateral(btcPair, user1, raw);

        (,,,, uint256 collAfter,,,,,,,,,) = btcPair.pairVault();
        uint256 pairUsdcAfter = usdc.balanceOf(address(btcPair));

        // Bookkeeping credited the rounded amount, not the raw value (no sub-µUSDC over-credit).
        assertEq(collAfter - collBefore, expected, "credited the rounded amount");
        // And it exactly matches the USDC actually pulled.
        assertEq(pairUsdcAfter - pairUsdcBefore, expected / 1e12, "credit equals USDC pulled, exactly");
    }

    // ==================== withdrawCollateral Tests ====================

    function testWithdrawCollateral_DirectCall_NoExposure() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        uint256 withdrawAmount = 40 * BAZAAR_SCALE;

        _depositCollateral(btcPair, user1, depositAmount);

        // Withdraw without price update (no open position)
        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        btcPair.withdrawCollateral(withdrawAmount, emptyPriceUpdate, 0, 0, 0, "");

        // Verify remaining collateral
        (,,, uint256 collateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(collateral, depositAmount - withdrawAmount);

        // Verify USDC returned to user
        uint256 user1BalanceAfterSetup = INITIAL_USER_BALANCE - PROPOSAL_TOTAL_USDC + bondUsdc;
        uint256 withdrawUsdc = withdrawAmount * USDC_SCALE / BAZAAR_SCALE;
        uint256 depositUsdc = depositAmount * USDC_SCALE / BAZAAR_SCALE;
        assertEq(usdc.balanceOf(user1), user1BalanceAfterSetup - depositUsdc + withdrawUsdc);
    }

    function testWithdrawCollateral_FullWithdrawal() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;

        _depositCollateral(btcPair, user1, depositAmount);

        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        btcPair.withdrawCollateral(depositAmount, emptyPriceUpdate, 0, 0, 0, "");

        // Verify collateral is zero
        (,,, uint256 collateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(collateral, 0);

        // Verify vault totalCollateralDeposited is zero
        (,,,, uint256 totalCollateral,,,,,,,,,) = btcPair.pairVault();
        assertEq(totalCollateral, 0);
    }

    function testWithdrawCollateral_EmitsEvent() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        uint256 withdrawAmount = 50 * BAZAAR_SCALE;

        _depositCollateral(btcPair, user1, depositAmount);

        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.expectEmit(true, true, false, true, address(btcPair));
        emit BazaarTypes.CollateralWithdrawn(btcPair.pairId(), user1, withdrawAmount);
        vm.prank(user1);
        btcPair.withdrawCollateral(withdrawAmount, emptyPriceUpdate, 0, 0, 0, "");
    }

    function testWithdrawCollateral_ViaRelayer() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        uint256 withdrawAmount = 50 * BAZAAR_SCALE;
        uint256 relayerFeeAmount = 5e16; // 0.05 USDC in BAZAAR_SCALE
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 10 seconds;

        _depositCollateral(btcPair, user1, depositAmount);

        bytes memory sig = _signWithdrawCollateral(btcPair, USER1_PK, withdrawAmount, nonce, deadline, relayerFeeAmount);

        // Relayer submits
        vm.prank(relayer);
        btcPair.withdrawCollateral(withdrawAmount, new bytes[](0), nonce, deadline, relayerFeeAmount, sig);

        // Verify remaining collateral
        (,,, uint256 collateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(collateral, depositAmount - withdrawAmount);

        // Verify user received withdrawal minus relayer fee
        uint256 user1BalanceAfterSetup = INITIAL_USER_BALANCE - PROPOSAL_TOTAL_USDC + bondUsdc;
        uint256 depositUsdc = depositAmount * USDC_SCALE / BAZAAR_SCALE;
        uint256 withdrawUsdc = withdrawAmount * USDC_SCALE / BAZAAR_SCALE;
        uint256 relayerFeeUsdc = relayerFeeAmount * USDC_SCALE / BAZAAR_SCALE;
        assertEq(usdc.balanceOf(user1), user1BalanceAfterSetup - depositUsdc + withdrawUsdc - relayerFeeUsdc);

        // The withheld fee accrued to the relayer's claimable balance; claiming pays it out
        (uint256 owed,) = btcPair.claimableFees(relayer);
        assertEq(owed, relayerFeeAmount);
        vm.prank(relayer);
        btcPair.claimFees();
        assertEq(usdc.balanceOf(relayer), relayerFeeUsdc);

        // Verify nonce incremented
        assertEq(btcPair.metaTxNonces(user1), 1);
    }

    function testWithdrawCollateral_RevertsZeroAmount() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        _depositCollateral(btcPair, user1, depositAmount);

        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(CollateralLib.CollateralLib__ZeroWithdrawalAmount.selector));
        btcPair.withdrawCollateral(0, emptyPriceUpdate, 0, 0, 0, "");
    }

    function testWithdrawCollateral_RevertsExceedsBalance() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        uint256 tooMuch = 200 * BAZAAR_SCALE;

        _depositCollateral(btcPair, user1, depositAmount);

        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralLib.CollateralLib__InsufficientCollateral.selector, tooMuch, depositAmount)
        );
        btcPair.withdrawCollateral(tooMuch, emptyPriceUpdate, 0, 0, 0, "");
    }

    function testWithdrawCollateral_RevertsNoCollateral() public {
        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralLib.CollateralLib__InsufficientCollateral.selector, 50 * BAZAAR_SCALE, 0)
        );
        btcPair.withdrawCollateral(50 * BAZAAR_SCALE, emptyPriceUpdate, 0, 0, 0, "");
    }

    function testWithdrawCollateral_MultipleWithdrawals() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        _depositCollateral(btcPair, user1, depositAmount);

        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.startPrank(user1);
        btcPair.withdrawCollateral(30 * BAZAAR_SCALE, emptyPriceUpdate, 0, 0, 0, "");
        btcPair.withdrawCollateral(20 * BAZAAR_SCALE, emptyPriceUpdate, 0, 0, 0, "");
        vm.stopPrank();

        (,,, uint256 collateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(collateral, 50 * BAZAAR_SCALE);
    }

    function testWithdrawCollateral_RelayerRevertsExpiredDeadline() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        _depositCollateral(btcPair, user1, depositAmount);

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 10 seconds;
        uint256 withdrawAmount = 50 * BAZAAR_SCALE;

        bytes memory sig = _signWithdrawCollateral(btcPair, USER1_PK, withdrawAmount, nonce, deadline, 0);

        vm.warp(deadline + 1);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(MetaTxLib.MetaTx__ExpiredDeadline.selector, deadline, block.timestamp));
        btcPair.withdrawCollateral(withdrawAmount, new bytes[](0), nonce, deadline, 0, sig);
    }

    function testWithdrawCollateral_RelayerRevertsWrongNonce() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        _depositCollateral(btcPair, user1, depositAmount);

        uint256 wrongNonce = 3;
        uint256 deadline = block.timestamp + 10 seconds;
        uint256 withdrawAmount = 50 * BAZAAR_SCALE;

        bytes memory sig = _signWithdrawCollateral(btcPair, USER1_PK, withdrawAmount, wrongNonce, deadline, 0);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(MetaTxLib.MetaTx__InvalidNonce.selector, 0, wrongNonce));
        btcPair.withdrawCollateral(withdrawAmount, new bytes[](0), wrongNonce, deadline, 0, sig);
    }

    function testWithdrawCollateral_RelayerRevertsRelayerFeeGteWithdrawAmount() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        _depositCollateral(btcPair, user1, depositAmount);

        uint256 withdrawAmount = 10 * BAZAAR_SCALE;
        uint256 relayerFeeAmount = 10 * BAZAAR_SCALE; // fee == withdraw amount
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 10 seconds;

        bytes memory sig = _signWithdrawCollateral(btcPair, USER1_PK, withdrawAmount, nonce, deadline, relayerFeeAmount);

        vm.prank(relayer);
        vm.expectRevert(); // "Withdraw amount <= relayer fee"
        btcPair.withdrawCollateral(withdrawAmount, new bytes[](0), nonce, deadline, relayerFeeAmount, sig);
    }

    function testWithdrawCollateral_VaultTotalCollateralUpdated() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        uint256 withdrawAmount = 30 * BAZAAR_SCALE;

        _depositCollateral(btcPair, user1, depositAmount);

        (,,,, uint256 totalBefore,,,,,,,,,) = btcPair.pairVault();
        assertEq(totalBefore, depositAmount);

        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        btcPair.withdrawCollateral(withdrawAmount, emptyPriceUpdate, 0, 0, 0, "");

        (,,,, uint256 totalAfter,,,,,,,,,) = btcPair.pairVault();
        assertEq(totalAfter, depositAmount - withdrawAmount);
    }

    function testWithdrawCollateral_WorksOnBothPairs() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        uint256 withdrawAmount = 40 * BAZAAR_SCALE;

        _depositCollateral(btcPair, user1, depositAmount);
        _depositCollateral(aaplPair, user2, depositAmount);

        bytes[] memory emptyPriceUpdate = new bytes[](0);

        vm.prank(user1);
        btcPair.withdrawCollateral(withdrawAmount, emptyPriceUpdate, 0, 0, 0, "");

        vm.prank(user2);
        aaplPair.withdrawCollateral(withdrawAmount, emptyPriceUpdate, 0, 0, 0, "");

        (,,, uint256 btcCollateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(btcCollateral, depositAmount - withdrawAmount);

        (,,, uint256 aaplCollateral,,,,,) = aaplPair.positionBuckets(user2);
        assertEq(aaplCollateral, depositAmount - withdrawAmount);
    }

    // ==================== Helper: Simulate Open Position ====================

    // BTC at $50,000 — 1 BTC long position, no PnL at this price
    uint256 constant BTC_PRICE_USD = 50_000;
    // Pyth encoding: $50,000 with expo=-8 → price.price = 5_000_000_000_000 (5e12)
    int64 constant BTC_PYTH_PRICE = 5_000_000_000_000;
    uint64 constant BTC_PYTH_CONF = 5_000_000_000; // $50 confidence (0.1%)
    int32 constant BTC_PYTH_EXPO = -8;
    // In BAZAAR_SCALE: convertExponent(5e12, -8, -18) = 5e12 * 10^10 = 5e22
    uint256 constant BTC_SPOT_PRICE = 50_000 * BAZAAR_SCALE;
    // 1 BTC position
    uint256 constant POSITION_SIZE = 1 * BAZAAR_SCALE;
    // notional = size * price / BAZAAR_SCALE = 1e18 * 5e22 / 1e18 = 5e22
    uint256 constant POSITION_NOTIONAL = BTC_PRICE_USD * BAZAAR_SCALE; // 5e22

    // pairVault starts at slot 7 (totalLongOI=7, totalShortOI=8, longWeightedEntrySum=9, shortWeightedEntrySum=10)
    uint256 constant SLOT_PAIR_VAULT_TOTAL_LONG_OI = 5;
    uint256 constant SLOT_PAIR_VAULT_LONG_WEIGHTED_ENTRY_SUM = 7;
    uint256 constant SLOT_PAIR_VAULT_PENDING_LIQ_SIZE = SLOT_PAIR_VAULT_TOTAL_LONG_OI + 6;
    uint256 constant SLOT_PAIR_VAULT_PENDING_LIQ_ENTRY_NOTIONAL = SLOT_PAIR_VAULT_TOTAL_LONG_OI + 7;
    uint256 constant SLOT_PAIR_VAULT_PENDING_LIQ_BANKRUPTCY_NOTIONAL = SLOT_PAIR_VAULT_TOTAL_LONG_OI + 8;
    uint256 constant SLOT_PAIR_VAULT_PENDING_LIQ_IS_LONG = SLOT_PAIR_VAULT_TOTAL_LONG_OI + 10;

    /// @dev Use stdstore to write a 1-BTC long position into user1's btcPair bucket.
    ///      Also updates vault OI so termination withdrawals don't underflow.
    ///      Collateral must already be deposited via _depositCollateral before calling this.
    function _simulateOpenPosition(address user) internal {
        BucketStore.setIsLong(address(btcPair), user, true); // isLong
        BucketStore.setSize(address(btcPair), user, POSITION_SIZE); // size
        BucketStore.setEntryValue(address(btcPair), user, POSITION_NOTIONAL); // entryValue

        // Update vault OI to match the simulated position
        bytes32 currentLongOI = vm.load(address(btcPair), bytes32(SLOT_PAIR_VAULT_TOTAL_LONG_OI));
        vm.store(
            address(btcPair), bytes32(SLOT_PAIR_VAULT_TOTAL_LONG_OI), bytes32(uint256(currentLongOI) + POSITION_SIZE)
        );
        bytes32 currentEntrySum = vm.load(address(btcPair), bytes32(SLOT_PAIR_VAULT_LONG_WEIGHTED_ENTRY_SUM));
        vm.store(
            address(btcPair),
            bytes32(SLOT_PAIR_VAULT_LONG_WEIGHTED_ENTRY_SUM),
            bytes32(uint256(currentEntrySum) + POSITION_NOTIONAL)
        );
    }

    /// @dev Build a MockPyth price update for BTC at $50,000 with the given publishTime.
    function _createBtcPriceUpdate(uint64 publishTime) internal view returns (bytes[] memory priceUpdate) {
        bytes memory priceData = mockPyth.createPriceFeedUpdateData(
            BTC_USD_FEED_ID,
            BTC_PYTH_PRICE,
            BTC_PYTH_CONF,
            BTC_PYTH_EXPO,
            BTC_PYTH_PRICE, // ema price same as price
            BTC_PYTH_CONF,
            publishTime,
            publishTime > 0 ? publishTime - 1 : 0
        );
        priceUpdate = new bytes[](1);
        priceUpdate[0] = priceData;
    }

    // ==================== withdrawCollateral With Open Position Tests ====================

    /// @dev isAdlPending is PACKED (slot 26, byte offset 20 — see `forge inspect BazaarPair
    ///      storage-layout`), which stdstore can't write; set the single byte via vm.store.
    function _setAdlPending(bool v) internal {
        bytes32 slot = bytes32(uint256(26));
        bytes32 cur = vm.load(address(btcPair), slot);
        bytes32 mask = bytes32(uint256(0xff) << (20 * 8));
        vm.store(address(btcPair), slot, (cur & ~mask) | bytes32(uint256(v ? 1 : 0) << (20 * 8)));
        assertEq(btcPair.isAdlPending(), v, "flag write landed");
    }

    /// @notice While ADL is pending, a position-holder's withdrawal is frozen: with trading
    ///         halted it can only strip margin or reorder-grief pending executeAdl submissions
    ///         (a winner's score rises as their cash falls, invalidating descending order).
    function testWithdrawCollateral_AdlPending_PositionHolderBlocked() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);
        _setAdlPending(true);

        vm.prank(user1);
        vm.expectRevert(BazaarPair.BazaarPair__WithdrawalsFrozenAdlPending.selector);
        btcPair.withdrawCollateral(1_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
    }

    /// @dev Give the vault real ADL pressure: it inherited a 1 BTC long with a $60,000
    ///      bankruptcy notional vs the $50,000 mark → $10k expected loss, above any threshold
    ///      on the empty insurance fund, so checkLiqExposure opens the ADL window.
    function _setPendingLiqPressure() internal {
        vm.store(address(btcPair), bytes32(SLOT_PAIR_VAULT_PENDING_LIQ_SIZE), bytes32(POSITION_SIZE));
        vm.store(
            address(btcPair), bytes32(SLOT_PAIR_VAULT_PENDING_LIQ_BANKRUPTCY_NOTIONAL), bytes32(60_000 * BAZAAR_SCALE)
        );
        // The exposure is measured from the entry basis, so the aggregate needs one: a long's
        // bankruptcy sits below entry by the collateral that was seized into the fund.
        vm.store(address(btcPair), bytes32(SLOT_PAIR_VAULT_PENDING_LIQ_ENTRY_NOTIONAL), bytes32(70_000 * BAZAAR_SCALE));
        vm.store(address(btcPair), bytes32(SLOT_PAIR_VAULT_PENDING_LIQ_IS_LONG), bytes32(uint256(1)));
        (,,,,,, uint256 pendingLiqSize,,,,,,,) = btcPair.pairVault();
        assertEq(pendingLiqSize, POSITION_SIZE, "pendingLiq write landed");
    }

    /// @notice The freeze must also catch the very transaction that OPENS the ADL window.
    ///         The pair-level guard reads isAdlPending before isVaultHealthy can set it
    ///         mid-call, so that one withdrawal is blocked by the CollateralLib reason-1
    ///         backstop instead of slipping through.
    function testWithdrawCollateral_AdlOpensMidCall_PositionHolderBlocked() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);
        // No pre-set flag — the pending-liquidation pressure alone must trip the window
        // during the withdrawal itself.
        _setPendingLiqPressure();
        assertFalse(btcPair.isAdlPending(), "window not open before the call");

        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));
        vm.prank(user1);
        vm.expectRevert(CollateralLib.CollateralLib__WithdrawalsFrozenAdlPending.selector);
        btcPair.withdrawCollateral(1_000 * BAZAAR_SCALE, priceUpdate, 0, 0, 0, "");
    }

    /// @notice Flat users (collateral only, no position) are NOT frozen during ADL pending —
    ///         they have no ADL score to manipulate and no margin role.
    function testWithdrawCollateral_AdlPending_FlatUserWithdraws() public {
        _depositCollateral(btcPair, user1, 5_000 * BAZAAR_SCALE);
        _setAdlPending(true);

        vm.prank(user1);
        btcPair.withdrawCollateral(1_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");

        (,,, uint256 collateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(collateral, 4_000 * BAZAAR_SCALE, "flat withdrawal proceeds during ADL pending");
    }

    function testWithdrawCollateral_WithPosition_RevertsNoPriceUpdate() public {
        // Deposit $15,000 collateral, open 1 BTC long
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        // Attempting to withdraw without a price update must revert
        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        vm.expectRevert(BazaarPair.BazaarPair__NoPriceUpdatesProvided.selector);
        btcPair.withdrawCollateral(1_000 * BAZAAR_SCALE, emptyPriceUpdate, 0, 0, 0, "");
    }

    function testWithdrawCollateral_WithPosition_RevertsStalePriceUpdate() public {
        // Deposit $15,000 collateral, open 1 BTC long
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        // Price published 40 seconds ago — far beyond MAX_PRICE_STALENESS
        bytes[] memory staleUpdate = _createBtcPriceUpdate(uint64(block.timestamp - 40));

        vm.prank(user1);
        vm.expectRevert(); // PythErrors.StalePrice()
        btcPair.withdrawCollateral(1_000 * BAZAAR_SCALE, staleUpdate, 0, 0, 0, "");
    }

    function testWithdrawCollateral_WithPosition_RevertsInsufficientMarginAfterWithdrawal() public {
        // Deposit $15,000 collateral, open 1 BTC long at $50,000 entry.
        // Pyth conf = $50 (0.1%), so a long bucket is valued at low = $49,950.
        // PnL = -$50, effectiveCollateral = $14,950, IMR = 20% × $49,950 = $9,990.
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        // Withdraw $6,000: equity $14,950 < IMR $9,990 + $6,000 → revert.
        uint256 excessiveWithdraw = 6_000 * BAZAAR_SCALE;
        uint256 expectedImr = 9_990 * BAZAAR_SCALE;
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralLib.CollateralLib__InsufficientMarginAfterWithdrawal.selector, excessiveWithdraw, expectedImr
            )
        );
        btcPair.withdrawCollateral(excessiveWithdraw, priceUpdate, 0, 0, 0, "");
    }

    function testWithdrawCollateral_WithPosition_SucceedsWithExcessCollateral() public {
        // Deposit $15,000 collateral, open 1 BTC long at $50,000 entry
        // IMR = 20% = $10,000 — user can safely withdraw up to $5,000
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        uint256 withdrawAmount = 4_000 * BAZAAR_SCALE;
        vm.prank(user1);
        btcPair.withdrawCollateral(withdrawAmount, priceUpdate, 0, 0, 0, "");

        // Collateral reduced by withdrawal amount
        (,,, uint256 remaining,,,,,) = btcPair.positionBuckets(user1);
        assertEq(remaining, 11_000 * BAZAAR_SCALE);

        // USDC transferred back to user
        uint256 withdrawUsdc = withdrawAmount * USDC_SCALE / BAZAAR_SCALE;
        uint256 user1BalanceAfterSetup = INITIAL_USER_BALANCE - PROPOSAL_TOTAL_USDC + bondUsdc;
        uint256 depositUsdc = 15_000 * USDC_SCALE;
        assertEq(usdc.balanceOf(user1), user1BalanceAfterSetup - depositUsdc + withdrawUsdc);

        // Position still open
        (, uint256 size,,,,,,,) = btcPair.positionBuckets(user1);
        assertEq(size, POSITION_SIZE);
    }

    // ==================== Helper: Create BTC Price Update at Custom Price ====================

    /// @dev Build a MockPyth price update for BTC at a custom USD price.
    function _createBtcPriceUpdateAtPrice(uint256 priceUsd, uint64 publishTime)
        internal
        view
        returns (bytes[] memory priceUpdate)
    {
        // Pyth encodes with expo=-8, so price.price = priceUsd * 1e8
        int64 pythPrice = int64(int256(priceUsd * 1e8));
        uint64 conf = uint64(priceUsd * 1e8 / 1000); // 0.1% confidence
        bytes memory priceData = mockPyth.createPriceFeedUpdateData(
            BTC_USD_FEED_ID,
            pythPrice,
            conf,
            BTC_PYTH_EXPO,
            pythPrice,
            conf,
            publishTime,
            publishTime > 0 ? publishTime - 1 : 0
        );
        priceUpdate = new bytes[](1);
        priceUpdate[0] = priceData;
    }

    // ==================== Helper: Terminate ====================

    // Storage layout constants — these target internal vars with no getter, so they are read
    // straight out of storage. Verify any change against `forge inspect BazaarPair
    // storage-layout`: adding or resizing a state variable declared earlier in BazaarPair shifts
    // every slot below it. The helpers assert a public getter afterward where one exists, so a
    // stale slot fails loudly rather than silently writing an unrelated word.
    uint256 constant SLOT_SCHEDULED_TERMINATION_TS = 30;

    /// @dev Terminate the pair for real at `termPrice`: fix the price, settle `user`'s position at
    ///      it (a flat user settles nothing), and finalize. Every scenario using this is
    ///      cash-covered, so both frozen payout ratios are 100%.
    function _terminateAt(BazaarPair pair, uint256 termPrice, address user) internal {
        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(termPrice);
        address[] memory users = new address[](1);
        users[0] = user;
        pair.liquidate(users, new bytes[](0));
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminated(), "pair terminated");
    }

    // ==================== Helper: Create Limit Order ====================

    /// @dev Creates a limit order for the given user on btcPair. Requires collateral + fresh price.
    ///      Callers pass prices that do not cross the resting book, so the order rests unfilled.
    function _createLimitOrder(address user, uint256 pk, bool isLong, uint256 size, uint256 limitPrice)
        internal
        returns (uint256)
    {
        pk; // silence unused-param (kept for call-site symmetry with signing helpers)
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: isLong,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: size,
                triggerPrice: 0, // not used for limit
                limitPrice: limitPrice,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0, // nonce (direct call)
            0, // deadline
            0, // relayerFee
            "", // signature (direct call)
            "" // permitData
        );

        return _lastCreatedOrderId(btcPair);
    }

    /// @dev Per-pair probe watermark for _lastCreatedOrderId.
    mapping(address => uint256) internal _idProbe;

    /// @dev The newest orderId a pair has assigned. Ids are a gapless monotonic counter from 1,
    ///      so probing forward finds the last created order even when it is already terminal
    ///      (a crossing or self-matching placement is filled/canceled in its own transaction,
    ///      so the active-order set is no source).
    function _lastCreatedOrderId(BazaarPair p) internal returns (uint256) {
        uint256 w = _idProbe[address(p)];
        if (w == 0) w = 1;
        while (true) {
            if (OrderView.order(p, w).creator == address(0)) break;
            ++w;
        }
        _idProbe[address(p)] = w;
        require(w > 1, "no orders created yet");
        return w - 1;
    }

    // ==================== withdrawCollateral: Normal Termination Tests ====================

    function testWithdrawCollateral_NormalTermination_NoPosition() public {
        uint256 depositAmount = 10_000 * BAZAAR_SCALE;
        _depositCollateral(btcPair, user1, depositAmount);

        // Normal termination at $50k — doesn't matter for user with no position
        _terminateAt(btcPair, BTC_SPOT_PRICE, user1);

        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        btcPair.withdrawCollateral(depositAmount, emptyPriceUpdate, 0, 0, 0, "");

        (,,, uint256 remaining,,,,,) = btcPair.positionBuckets(user1);
        assertEq(remaining, 0);

        // Vault totalCollateralDeposited should be zero
        (,,,, uint256 totalCollateral,,,,,,,,,) = btcPair.pairVault();
        assertEq(totalCollateral, 0);
    }

    function testWithdrawCollateral_NormalTermination_LongWithLoss() public {
        // Deposit $15,000, open 1 BTC long at $50,000 entry
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        // Normal termination at $40,000 — user loses $10,000, and this contract settles the
        // position for them, so the bucket also pays TERMINAL_SETTLEMENT_TIP.
        // Collateral becomes 15000 - 10000 - 0.1 = 4999.9
        _terminateAt(btcPair, 40_000 * BAZAAR_SCALE, user1);
        uint256 expected = 5_000 * BAZAAR_SCALE - BazaarTypes.TERMINAL_SETTLEMENT_TIP;

        (uint256 owed,) = btcPair.claimableFees(address(this));
        assertEq(owed, BazaarTypes.TERMINAL_SETTLEMENT_TIP, "settler tipped from the bucket");

        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        btcPair.withdrawCollateral(expected, emptyPriceUpdate, 0, 0, 0, "");

        (, uint256 size,, uint256 collateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(collateral, 0, "collateral less the loss and the tip, fully withdrawn");
        assertEq(size, 0, "position closed by settlement");
    }

    function testWithdrawCollateral_NormalTermination_LongWithLoss_RevertsExceedsAvailable() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        // Normal termination at $40,000 — user's collateral after PnL = 5000
        _terminateAt(btcPair, 40_000 * BAZAAR_SCALE, user1);

        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        vm.expectRevert(); // "Exceeds available collateral"
        btcPair.withdrawCollateral(6_000 * BAZAAR_SCALE, emptyPriceUpdate, 0, 0, 0, "");
    }

    // ==================== withdrawCollateral: Scheduled Termination Tests ====================

    function testWithdrawCollateral_PendingTermination_Reverts() public {
        uint256 depositAmount = 10_000 * BAZAAR_SCALE;
        _depositCollateral(btcPair, user1, depositAmount);

        // Set scheduled termination in the past (pending but not yet executed)
        vm.store(address(btcPair), bytes32(SLOT_SCHEDULED_TERMINATION_TS), bytes32(block.timestamp - 1));

        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(CollateralLib.CollateralLib__PairScheduledForTermination.selector, 0));
        btcPair.withdrawCollateral(depositAmount, emptyPriceUpdate, 0, 0, 0, "");
    }

    // ==================== withdrawCollateral: Price Staleness Tests ====================

    /// @dev MAX_PRICE_STALENESS applies to the supplied update whoever submits it, so the same
    ///      over-age price is rejected on the relayed path and the direct one alike. A zero-fee
    ///      relay is covered explicitly because it is the cheapest way to reach the meta-tx
    ///      branch, and nothing about the fee should move the freshness gate.
    function testWithdrawCollateral_MetaTxZeroFee_RejectsStalePrice() public {
        // Deposit and open position
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        // Price published 5 seconds ago — beyond MAX_PRICE_STALENESS
        bytes[] memory staleUpdate = _createBtcPriceUpdate(uint64(block.timestamp - 5));

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 10 seconds;
        uint256 relayerFee = 0; // zero fee relay

        bytes memory sig = _signWithdrawCollateral(btcPair, USER1_PK, 1_000 * BAZAAR_SCALE, nonce, deadline, relayerFee);

        vm.prank(relayer);
        vm.expectRevert(); // stale price
        btcPair.withdrawCollateral(1_000 * BAZAAR_SCALE, staleUpdate, nonce, deadline, relayerFee, sig);
    }

    function testWithdrawCollateral_DirectCall_RejectsStalePrice() public {
        // Deposit and open position
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        // Price published 5 seconds ago — beyond MAX_PRICE_STALENESS
        bytes[] memory staleUpdate = _createBtcPriceUpdate(uint64(block.timestamp - 5));

        vm.prank(user1);
        vm.expectRevert(); // stale price
        btcPair.withdrawCollateral(1_000 * BAZAAR_SCALE, staleUpdate, 0, 0, 0, "");
    }

    /// @dev Pins the accepting edge of the window: Pyth admits an update whose age equals the
    ///      bound, so 2s old must still settle a direct withdrawal. Without this the reverting
    ///      cases above would also pass if the gate had collapsed to "only a same-second price".
    function testWithdrawCollateral_DirectCall_AcceptsPriceAtStalenessBound() public {
        // Deposit and open position
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        // Price published exactly MAX_PRICE_STALENESS ago — the oldest update still admissible
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp - 2));

        vm.prank(user1);
        btcPair.withdrawCollateral(1_000 * BAZAAR_SCALE, priceUpdate, 0, 0, 0, "");

        (,,, uint256 remaining,,,,,) = btcPair.positionBuckets(user1);
        assertEq(remaining, 14_000 * BAZAAR_SCALE);
    }

    // ==================== withdrawCollateral: Relayer Fee Deduction Tests ====================

    function testWithdrawCollateral_RelayerFeeDeductedFromWithdrawal() public {
        uint256 depositAmount = 100 * BAZAAR_SCALE;
        uint256 withdrawAmount = 50 * BAZAAR_SCALE;
        uint256 relayerFeeAmount = 5e16; // 0.05 USDC in BAZAAR_SCALE
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 10 seconds;

        _depositCollateral(btcPair, user1, depositAmount);

        bytes memory sig = _signWithdrawCollateral(btcPair, USER1_PK, withdrawAmount, nonce, deadline, relayerFeeAmount);

        uint256 user1BalanceBefore = usdc.balanceOf(user1);

        vm.prank(relayer);
        btcPair.withdrawCollateral(withdrawAmount, new bytes[](0), nonce, deadline, relayerFeeAmount, sig);

        // User receives withdrawal minus relayer fee; the fee is owed to the relayer
        uint256 withdrawUsdc = withdrawAmount * USDC_SCALE / BAZAAR_SCALE;
        uint256 relayerFeeUsdc = relayerFeeAmount * USDC_SCALE / BAZAAR_SCALE;
        assertEq(usdc.balanceOf(user1), user1BalanceBefore + withdrawUsdc - relayerFeeUsdc);
        (uint256 owed,) = btcPair.claimableFees(relayer);
        assertEq(owed, relayerFeeAmount);

        // Collateral reduced by full withdrawal amount (fee comes from the withdrawal, not collateral)
        (,,, uint256 remaining,,,,,) = btcPair.positionBuckets(user1);
        assertEq(remaining, depositAmount - withdrawAmount);
    }

    // ==================== withdrawCollateral: PnL Tests ====================

    function testWithdrawCollateral_WithPosition_PriceUp_MoreEquity() public {
        // Deposit $15,000, open 1 BTC long at $50,000 entry
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        // BTC moves to $55,000 — unrealized profit = $5,000
        // Available equity = 15,000 + 5,000 = 20,000
        // IMR = 20% of $55,000 = $11,000
        // Max withdraw = 20,000 - 11,000 = $9,000
        bytes[] memory priceUpdate = _createBtcPriceUpdateAtPrice(55_000, uint64(block.timestamp));

        uint256 withdrawAmount = 8_000 * BAZAAR_SCALE;
        vm.prank(user1);
        btcPair.withdrawCollateral(withdrawAmount, priceUpdate, 0, 0, 0, "");

        // Withdrawal succeeds — position still open
        (, uint256 size,,,,,,,) = btcPair.positionBuckets(user1);
        assertEq(size, POSITION_SIZE);
    }

    function testWithdrawCollateral_WithPosition_PriceDown_LessEquity() public {
        // Deposit $15,000, open 1 BTC long at $50,000 entry
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        // BTC drops to $45,000 — unrealized loss = $5,000
        // Available equity = 15,000 - 5,000 = 10,000
        // IMR = 20% of $45,000 = $9,000
        // Max withdraw = 10,000 - 9,000 = $1,000
        bytes[] memory priceUpdate = _createBtcPriceUpdateAtPrice(45_000, uint64(block.timestamp));

        // Trying to withdraw $2,000 should fail
        vm.prank(user1);
        vm.expectRevert();
        btcPair.withdrawCollateral(2_000 * BAZAAR_SCALE, priceUpdate, 0, 0, 0, "");
    }

    function testWithdrawCollateral_WithPosition_PriceDown_SmallWithdrawSucceeds() public {
        // Deposit $15,000, open 1 BTC long at $50,000 entry
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        // BTC drops to $45,000 — max withdraw ~ $1,000
        bytes[] memory priceUpdate = _createBtcPriceUpdateAtPrice(45_000, uint64(block.timestamp));

        vm.prank(user1);
        btcPair.withdrawCollateral(500 * BAZAAR_SCALE, priceUpdate, 0, 0, 0, "");

        (, uint256 size,,,,,,,) = btcPair.positionBuckets(user1);
        assertEq(size, POSITION_SIZE);
    }

    // ==================== withdrawCollateral: Exact Margin Boundary Tests ====================

    function testWithdrawCollateral_WithPosition_ExactMaxWithdraw() public {
        // Deposit $15,000, open 1 BTC long at $50,000 entry.
        // Long bucket valued at low = $49,950 (mid - 0.1% Pyth conf).
        // Equity = $15,000 + (49,950 - 50,000) = $14,950
        // IMR = 20% × $49,950 = $9,990
        // Max withdraw = $14,950 - $9,990 = $4,960
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        btcPair.withdrawCollateral(4_960 * BAZAAR_SCALE, priceUpdate, 0, 0, 0, "");

        (, uint256 size,,,,,,,) = btcPair.positionBuckets(user1);
        assertEq(size, POSITION_SIZE);
    }

    function testWithdrawCollateral_WithPosition_ExactMaxWithdrawPlusOneReverts() public {
        // Same setup — max withdraw = $5,000, try $5,001
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert();
        btcPair.withdrawCollateral(5_001 * BAZAAR_SCALE, priceUpdate, 0, 0, 0, "");
    }

    /// @dev Mirror of _simulateOpenPosition for the AAPL pair: bucket fields straight into
    ///      storage plus the vault OI aggregates the health checks read.
    function _simulateAaplLong(address user, uint256 size, uint256 entryValue) internal {
        BucketStore.setIsLong(address(aaplPair), user, true); // isLong
        BucketStore.setSize(address(aaplPair), user, size);
        BucketStore.setEntryValue(address(aaplPair), user, entryValue);

        bytes32 currentLongOI = vm.load(address(aaplPair), bytes32(SLOT_PAIR_VAULT_TOTAL_LONG_OI));
        vm.store(address(aaplPair), bytes32(SLOT_PAIR_VAULT_TOTAL_LONG_OI), bytes32(uint256(currentLongOI) + size));
        bytes32 currentEntrySum = vm.load(address(aaplPair), bytes32(SLOT_PAIR_VAULT_LONG_WEIGHTED_ENTRY_SUM));
        vm.store(
            address(aaplPair),
            bytes32(SLOT_PAIR_VAULT_LONG_WEIGHTED_ENTRY_SUM),
            bytes32(uint256(currentEntrySum) + entryValue)
        );
    }

    /// @dev Build a MockPyth price update for AAPL at an arbitrary price (expo -8, 0.1% conf).
    function _createAaplPriceUpdateAtPrice(uint256 priceUsd, uint64 publishTime)
        internal
        view
        returns (bytes[] memory priceUpdate)
    {
        int64 pythPrice = int64(int256(priceUsd * 1e8));
        uint64 conf = uint64(priceUsd * 1e8 / 1000);
        bytes memory priceData = mockPyth.createPriceFeedUpdateData(
            AAPL_USD_FEED_ID,
            pythPrice,
            conf,
            BTC_PYTH_EXPO,
            pythPrice,
            conf,
            publishTime,
            publishTime > 0 ? publishTime - 1 : 0
        );
        priceUpdate = new bytes[](1);
        priceUpdate[0] = priceData;
    }

    /// @notice A session-bound pair retains INITIAL margin in cash: unrealized profit cannot
    ///         substitute for any of it, because a reopen gap can erase the profit in the same
    ///         jump that needs the buffer, with no chance for liquidation to interpose.
    ///         (Continuously traded pairs retain maintenance-level cash instead — the
    ///         RetainedCollateralFloorTest suite covers that branch on the BTC pair.)
    function testWithdrawCollateral_NonContinuous_RetainsImrInCash() public {
        uint256 deposit = 1_000 * BAZAAR_SCALE;
        _depositCollateral(aaplPair, user2, deposit);
        _simulateAaplLong(user2, 1 * BAZAAR_SCALE, 200 * BAZAAR_SCALE); // 1 AAPL @ $200 entry

        // Price triples to $600: unrealized profit (~$400) alone covers the IMR requirement.
        bytes[] memory priceUpdate = _createAaplPriceUpdateAtPrice(600, uint64(block.timestamp));

        (uint256 imrBp, uint256 mmrBp,,,) = aaplPair.marginRequirements();
        uint256 lowPrice = 600 * BAZAAR_SCALE - (600 * BAZAAR_SCALE / 1000); // long bracket: spot - 0.1% conf
        uint256 floorAmt = imrBp * lowPrice / 10_000; // 1-unit position: notional == lowPrice
        assertGt(floorAmt, mmrBp * lowPrice / 10_000, "imr floor strictly above the continuous pairs' mmr floor");

        // Withdrawing the whole deposit is blocked by the IMR-cash floor — not by equity, which
        // profit alone keeps far above the requirement.
        vm.prank(user2);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralLib.CollateralLib__MustRetainMinimumCollateral.selector, 0, floorAmt)
        );
        aaplPair.withdrawCollateral(deposit, priceUpdate, 0, 0, 0, "");

        // Withdrawing down TO the floor clears every gate.
        priceUpdate = _createAaplPriceUpdateAtPrice(600, uint64(block.timestamp));
        vm.prank(user2);
        aaplPair.withdrawCollateral(deposit - floorAmt, priceUpdate, 0, 0, 0, "");
        (,,, uint256 remaining,,,,,) = aaplPair.positionBuckets(user2);
        assertEq(remaining, floorAmt, "retains exactly initial margin in cash");
    }

    // ==================== withdrawCollateral: Order Exposure Tests ====================

    function testWithdrawCollateral_NoPosition_WithLimitOrder_MarginReserved() public {
        // Deposit $15,000, no position, but place a limit buy order for 1 BTC at $50,000
        // Order notional = 1 * 50,000 = $50,000
        // IMR required = 20% of $50,000 = $10,000
        // Max withdraw = 15,000 - 10,000 = $5,000
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        btcPair.withdrawCollateral(5_000 * BAZAAR_SCALE, emptyPriceUpdate, 0, 0, 0, "");

        (,,, uint256 remaining,,,,,) = btcPair.positionBuckets(user1);
        assertEq(remaining, 10_000 * BAZAAR_SCALE);

        // Vault totalCollateralDeposited decreased by withdrawal
        (,,,, uint256 totalCollateral,,,,,,,,,) = btcPair.pairVault();
        assertEq(totalCollateral, 10_000 * BAZAAR_SCALE);
    }

    function testWithdrawCollateral_NoPosition_WithLimitOrder_RevertsInsufficientMargin() public {
        // Same setup — max withdraw = $5,000, try $6,000
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        vm.expectRevert();
        btcPair.withdrawCollateral(6_000 * BAZAAR_SCALE, emptyPriceUpdate, 0, 0, 0, "");
    }

    function testWithdrawCollateral_WithPosition_AndLimitOrder_WorstCaseExposure() public {
        // Deposit $25,000, open 1 BTC long at $50,000 entry
        _depositCollateral(btcPair, user1, 25_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        // Place another long limit order for 1 BTC at $50,000
        // Worst case same-dir exposure: position notional ($50k) + order notional ($50k) = $100k
        // IMR = 20% of $100k = $20,000
        // Available equity = $25,000 (zero PnL at current price)
        // Max withdraw = $25,000 - $20,000 = $5,000
        _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        btcPair.withdrawCollateral(4_000 * BAZAAR_SCALE, priceUpdate, 0, 0, 0, "");

        (, uint256 size,,,,,,,) = btcPair.positionBuckets(user1);
        assertEq(size, POSITION_SIZE);
    }

    function testWithdrawCollateral_WithPosition_AndLimitOrder_WorstCaseExposure_RevertsExcessive() public {
        _depositCollateral(btcPair, user1, 25_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);
        _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        // Max withdraw ~ $5,000, try $6,000
        vm.prank(user1);
        vm.expectRevert();
        btcPair.withdrawCollateral(6_000 * BAZAAR_SCALE, priceUpdate, 0, 0, 0, "");
    }

    function testWithdrawCollateral_NoPosition_FullWithdrawAfterCancellingOrders() public {
        // Deposit, place order, cancel order, then withdraw everything
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        uint256 orderId = _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        // Cancel the order
        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = orderId;
        vm.prank(user1);
        btcPair.cancelOrders(orderIds, 0, 0, 0, "", "");

        // Now should be able to withdraw everything
        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        btcPair.withdrawCollateral(15_000 * BAZAAR_SCALE, emptyPriceUpdate, 0, 0, 0, "");

        (,,, uint256 remaining,,,,,) = btcPair.positionBuckets(user1);
        assertEq(remaining, 0);

        // Vault totalCollateralDeposited should be zero
        (,,,, uint256 totalCollateral,,,,,,,,,) = btcPair.pairVault();
        assertEq(totalCollateral, 0);
    }

    // ==================== Helper: Create Order Convenience ====================

    /// @dev Creates a market order for the given user on btcPair. Market orders match against
    ///      the book inside createOrder itself; any unfilled remainder auto-cancels in the same
    ///      transaction, so the stored order is terminal when this returns.
    function _createMarketOrder(address user, bool isLong, uint256 size, uint256 maxSlippageBp) internal {
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Market,
                isLong: isLong,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: size,
                triggerPrice: 0,
                limitPrice: 0,
                maxSlippageBp: maxSlippageBp,
                expirationBlock: 0, // ignored for market
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "", // direct call
            "" // permitData
        );
    }

    /// @dev Helper to sign a createOrder meta-tx
    function _signCreateOrder(
        BazaarPair pair,
        uint256 privateKey,
        BazaarTypes.OrderType orderType,
        uint256 triggerPrice,
        uint256 limitPrice,
        uint256 maxSlippageBp,
        uint256 size,
        bool isLong,
        bool isPostOnly,
        uint64 expirationBlock,
        address integrator,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                MetaTxLib.CREATE_ORDER_TYPEHASH,
                orderType,
                triggerPrice,
                limitPrice,
                maxSlippageBp,
                size,
                isLong,
                isPostOnly,
                BazaarTypes.TimeInForce.GTC, // every meta-tx order in this suite is GTC
                expirationBlock,
                integrator,
                nonce,
                deadline,
                relayerFee
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(pair.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ==================== createOrder: Limit Order Tests ====================

    function testCreateOrder_LimitOrder_Long() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        uint256 limitPrice = BTC_SPOT_PRICE;
        uint256 size = POSITION_SIZE;
        uint64 expiry = uint64(block.number + 500_000);

        vm.expectEmit(true, true, true, true, address(btcPair));
        emit BazaarTypes.OrderUpdated(
            btcPair.pairId(),
            1,
            user1,
            BazaarTypes.OrderUpdatePayload({
                action: BazaarTypes.OrderAction.Created,
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                size: size,
                filledSize: 0,
                triggerPrice: 0,
                limitPrice: limitPrice,
                maxSlippageBp: 0,
                canceledBlock: 0,
                filledBlock: 0,
                expiryBlock: expiry,
                creationBlock: uint64(block.number)
            })
        );

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: size,
                triggerPrice: 0,
                limitPrice: limitPrice,
                maxSlippageBp: 0,
                expirationBlock: expiry,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        // Verify order stored
        BazaarTypes.Order memory o = OrderView.order(btcPair, 1);
        (address creator, uint256 lp, uint256 s, BazaarTypes.OrderType ot, bool isLong) =
            (o.creator, o.limitPrice, o.size, o.orderType, o.isLong);
        assertEq(creator, user1);
        assertTrue(ot == BazaarTypes.OrderType.Limit);
        assertEq(lp, limitPrice);
        assertEq(s, size);
        assertTrue(isLong);

        // Verify tracked in userActiveLimitOrders
        (uint256[] memory activeOrders, uint256 count,,) = btcPair.getUserActiveLimitOrders(user1);
        assertEq(count, 1);
        assertEq(activeOrders[0], 1);
    }

    function testCreateOrder_LimitOrder_Short() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: false,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        BazaarTypes.Order memory o = OrderView.order(btcPair, 1);
        (address creator, uint256 filledSize, bool isLong) = (o.creator, o.filledSize, o.isLong);
        assertEq(creator, user1);
        assertFalse(isLong);
        assertEq(filledSize, 0);
    }

    function testCreateOrder_LimitOrder_PostOnly() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: true,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        bool isPostOnly = OrderView.order(btcPair, 1).isPostOnly;
        assertTrue(isPostOnly);
    }

    function testCreateOrder_LimitOrder_RevertsZeroLimitPrice() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(OrderManagementLib.OrderManagementLib__ZeroLimitPrice.selector);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: 0, // rejected
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    // ==================== createOrder: Market Order Tests ====================

    function testCreateOrder_MarketOrder_Long() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Market,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: 0,
                maxSlippageBp: 100, // 1% slippage
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        // A market order is terminal within its own transaction: it matches on arrival and any
        // unfilled remainder auto-cancels. Stored with triggerPrice = currentPrice and
        // expiryBlock = creationBlock; here the book is empty, so nothing fills and the whole
        // size is canceled in the creation block.
        BazaarTypes.Order memory o = OrderView.order(btcPair, 1);
        (uint256 tp, uint256 filledSize, BazaarTypes.OrderType ot) = (o.triggerPrice, o.filledSize, o.orderType);
        (uint64 creationBlock, uint64 expiryBlock, uint64 canceledBlock) =
            (o.creationBlock, o.expiryBlock, o.canceledBlock);
        assertTrue(ot == BazaarTypes.OrderType.Market);
        assertEq(tp, BTC_SPOT_PRICE); // triggerPrice set to current price
        assertEq(expiryBlock, creationBlock); // never outlives its own transaction
        assertEq(filledSize, 0); // empty book — nothing crossed
        assertEq(canceledBlock, creationBlock); // remainder auto-canceled on arrival
    }

    function testCreateOrder_MarketOrder_RevertsPostOnly() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(OrderManagementLib.OrderManagementLib__PostOnlyNotAllowed.selector);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Market,
                isLong: true,
                isPostOnly: true, // rejected
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: 0,
                maxSlippageBp: 100,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_MarketOrder_RevertsZeroSlippage() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__InvalidSlippage.selector, 0));
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Market,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: 0,
                maxSlippageBp: 0, // rejected
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_MarketOrder_RevertsExcessiveSlippage() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__InvalidSlippage.selector, 1001));
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Market,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: 0,
                maxSlippageBp: 1001, // exceeds MAX_SLIPPAGE_BP (1000)
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    /// @dev `maxSlippageBp` doubles as the market-order priority key in the matching walk, where a
    ///      wider tolerance sorts ahead. A market order's required margin is therefore
    ///      side-independent and strictly increasing in slippage, so queue position can never be
    ///      bought for less margin than a tight tolerance costs.
    function testCreateOrder_MarketOrder_WiderSlippageCostsMoreMarginOnBothSides() public {
        // Deliberately far below any requirement, so every attempt reverts and reports its own
        // requiredMargin rather than opening a position that would shift later attempts' baseline.
        _depositCollateral(btcPair, user1, 5 * BAZAAR_SCALE);

        uint256 longTight = _marketOrderRequiredMargin(true, POSITION_SIZE, 1);
        uint256 longWide = _marketOrderRequiredMargin(true, POSITION_SIZE, 500);
        uint256 shortTight = _marketOrderRequiredMargin(false, POSITION_SIZE, 1);
        uint256 shortWide = _marketOrderRequiredMargin(false, POSITION_SIZE, 500);

        assertGt(longWide, longTight, "long: wider slippage must cost more margin");
        assertGt(shortWide, shortTight, "short: wider slippage must cost more margin");
        assertEq(shortTight, longTight, "tight slippage must cost the same on both sides");
        assertEq(shortWide, longWide, "wide slippage must cost the same on both sides");
    }

    /// @dev Attempts a market order that cannot be margined and returns the `requiredMargin` the
    ///      revert reports. Reverts the test if the order is admitted or fails for another reason.
    function _marketOrderRequiredMargin(bool isLong, uint256 size, uint256 maxSlippageBp)
        internal
        returns (uint256 requiredMargin)
    {
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        try btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Market,
                isLong: isLong,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: size,
                triggerPrice: 0,
                limitPrice: 0,
                maxSlippageBp: maxSlippageBp,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        ) {
            revert("expected InsufficientMarginAfterOrder");
        } catch (bytes memory err) {
            // Revert payload is selector + (effectiveCollateral, requiredMargin); read the second.
            require(err.length == 68, "unexpected revert payload");
            bytes4 sel;
            assembly {
                sel := mload(add(err, 0x20))
                requiredMargin := mload(add(err, 0x44))
            }
            assertEq(
                sel,
                OrderManagementLib.OrderManagementLib__InsufficientMarginAfterOrder.selector,
                "wrong revert selector"
            );
        }
    }

    // ==================== createOrder: StopLimit Order Tests ====================

    function testCreateOrder_StopLimit() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        // Buy StopLimit: limit must be >= trigger (fillable side). The $50k oracle price already
        // meets the $48k buy trigger (buy arms at price >= trigger, inclusive), so the stop arms
        // in the creation transaction and rests in the book as a buy limit — the stored trigger
        // and limit fields are unchanged by arming.
        uint256 triggerPrice = 48_000 * BAZAAR_SCALE;
        uint256 limitPrice = 48_500 * BAZAAR_SCALE;

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.StopLimit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: triggerPrice,
                limitPrice: limitPrice,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        BazaarTypes.Order memory o = OrderView.order(btcPair, 1);
        (uint256 tp, uint256 lp, BazaarTypes.OrderType ot) = (o.triggerPrice, o.limitPrice, o.orderType);
        assertTrue(ot == BazaarTypes.OrderType.StopLimit);
        assertEq(tp, triggerPrice);
        assertEq(lp, limitPrice);
    }

    function testCreateOrder_StopLimit_RevertsPostOnly() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(OrderManagementLib.OrderManagementLib__PostOnlyNotAllowed.selector);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.StopLimit,
                isLong: true,
                isPostOnly: true, // rejected before any other stop validation
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 48_000 * BAZAAR_SCALE,
                limitPrice: 47_500 * BAZAAR_SCALE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_StopLimit_RevertsZeroTriggerPrice() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(OrderManagementLib.OrderManagementLib__ZeroTriggerPrice.selector);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.StopLimit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0, // rejected
                limitPrice: 47_500 * BAZAAR_SCALE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_StopLimit_RevertsZeroLimitPrice() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(OrderManagementLib.OrderManagementLib__ZeroLimitPrice.selector);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.StopLimit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 48_000 * BAZAAR_SCALE,
                limitPrice: 0, // rejected
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    // ==================== createOrder: Common Validation Tests ====================

    function testCreateOrder_RevertsZeroSize() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(OrderManagementLib.OrderManagementLib__ZeroSize.selector);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: 0, // rejected
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_RevertsNotionalBelowMinimum() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        // Size such that notional = size * price / BAZAAR_SCALE < 5 USDC (= 5 * BAZAAR_SCALE)
        // At $50,000 per BTC, need size < 5 * 1e18 / 50000 = 1e14
        uint256 tinySize = 1e13; // notional = 1e13 * 5e22 / 1e18 = 5e17 = 0.5 USDC
        uint256 expectedNotional = tinySize * BTC_SPOT_PRICE / BAZAAR_SCALE;

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderManagementLib.OrderManagementLib__NotionalBelowMinimum.selector, expectedNotional, 5 * BAZAAR_SCALE
            )
        );
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: tinySize,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    /// @dev Writes a dust long into user1's bucket: entered at $5 notional, now worth $4 at the
    ///      $50k spot (entryValue reflects a higher entry price). Mirrors _simulateOpenPosition.
    uint256 constant DUST_SIZE = 8e13; // 8e13 × $50k / 1e18 = $4 notional now
    uint256 constant DUST_ENTRY_VALUE = 5e18; // $5 notional at entry

    function _simulateDustLong(address user) internal {
        BucketStore.setIsLong(address(btcPair), user, true); // isLong
        BucketStore.setSize(address(btcPair), user, DUST_SIZE); // size
        BucketStore.setEntryValue(address(btcPair), user, DUST_ENTRY_VALUE); // entryValue
    }

    /// @notice A market order that fully closes the position is exempt from MIN_ORDER_AMOUNT:
    ///         a position whose notional drifted under the floor must remain closable at market.
    function testCreateOrder_FullCloseBelowMinimum_MarketAllowed() public {
        _depositCollateral(btcPair, user1, 100 * BAZAAR_SCALE);
        _simulateDustLong(user1);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Market,
                isLong: false, // full-size sell, $4 notional < $5 floor
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: DUST_SIZE,
                triggerPrice: 0,
                limitPrice: 0,
                maxSlippageBp: 100,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        BazaarTypes.Order memory o = OrderView.order(btcPair, 1);
        (uint256 sz, BazaarTypes.OrderType ot) = (o.size, o.orderType);
        assertTrue(ot == BazaarTypes.OrderType.Market, "full-close market order created");
        assertEq(sz, DUST_SIZE, "order covers the whole position");
    }

    /// @notice Same exemption applies to a full-close limit order priced under the floor.
    function testCreateOrder_FullCloseBelowMinimum_LimitAllowed() public {
        _depositCollateral(btcPair, user1, 100 * BAZAAR_SCALE);
        _simulateDustLong(user1);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: false, // sell limit at spot, $4 notional
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: DUST_SIZE,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        BazaarTypes.Order memory o = OrderView.order(btcPair, 1);
        (uint256 sz, BazaarTypes.OrderType ot) = (o.size, o.orderType);
        assertTrue(ot == BazaarTypes.OrderType.Limit, "full-close limit order created");
        assertEq(sz, DUST_SIZE, "order covers the whole position");
    }

    /// @notice A partial reduce below the floor is NOT exempt — sub-minimum residual positions
    ///         can't be minted deliberately.
    function testCreateOrder_PartialCloseBelowMinimum_StillReverts() public {
        _depositCollateral(btcPair, user1, 100 * BAZAAR_SCALE);
        _simulateDustLong(user1);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        uint256 halfSize = DUST_SIZE / 2; // ~$2 notional, leaves a ~$2 residual

        vm.prank(user1);
        vm.expectPartialRevert(OrderManagementLib.OrderManagementLib__NotionalBelowMinimum.selector);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Market,
                isLong: false,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: halfSize,
                triggerPrice: 0,
                limitPrice: 0,
                maxSlippageBp: 100,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    /// @notice A same-direction (position-increasing) order below the floor is NOT exempt,
    ///         even when its size equals the existing position.
    function testCreateOrder_SameDirectionBelowMinimum_StillReverts() public {
        _depositCollateral(btcPair, user1, 100 * BAZAAR_SCALE);
        _simulateDustLong(user1);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectPartialRevert(OrderManagementLib.OrderManagementLib__NotionalBelowMinimum.selector);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Market,
                isLong: true, // BUY — adds to the long, not a close
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: DUST_SIZE,
                triggerPrice: 0,
                limitPrice: 0,
                maxSlippageBp: 100,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_RevertsInsufficientMargin() public {
        // Deposit only $1,000 but try to place order for 1 BTC ($50,000 notional)
        // IMR = 20% warmup = $10,000 required
        _depositCollateral(btcPair, user1, 1_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(); // InsufficientMarginAfterOrder
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_RevertsInvalidExpiration_TooSoon() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        // Expiration less than MIN_ORDER_LIFETIME_BLOCKS (12) from current block
        uint64 tooSoonExpiration = uint64(block.number + 2);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderManagementLib.OrderManagementLib__InvalidOrderExpiration.selector, tooSoonExpiration
            )
        );
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: tooSoonExpiration,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_ExpirationClampedToMaxLifetime() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        // Expiration exceeds MAX_ORDER_LIFETIME_BLOCKS — should be clamped
        uint64 farExpiration = uint64(block.number + 200_000_000);

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: farExpiration,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        BazaarTypes.Order memory o = OrderView.order(btcPair, 1);
        (uint64 creationBlock, uint64 expiryBlock) = (o.creationBlock, o.expiryBlock);
        assertEq(expiryBlock, creationBlock + 365 * 24 * 60 * 60 * 4); // MAX_ORDER_LIFETIME_BLOCKS
    }

    function testCreateOrder_RevertsTradingHalted_NormalTerminated() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _terminateAt(btcPair, BTC_SPOT_PRICE, user1);

        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(BazaarPair.BazaarPair__TradingHalted.selector);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_RevertsPairScheduledForTermination() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);

        // Set scheduled termination in the past
        vm.store(address(btcPair), bytes32(SLOT_SCHEDULED_TERMINATION_TS), bytes32(block.timestamp - 1));

        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(BazaarPair.BazaarPair__PairScheduledForTermination.selector);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_RevertsNoPriceUpdate() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory emptyPriceUpdate = new bytes[](0);

        vm.prank(user1);
        vm.expectRevert(BazaarPair.BazaarPair__NoPriceUpdatesProvided.selector);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            emptyPriceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    // ==================== createOrder: TP/SL Tests ====================

    function testCreateOrder_TakeProfit_Long() public {
        // Open a long position, then set TP above current price
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1); // 1 BTC long at $50,000

        // Sell take-profit $5k above spot: untriggered at creation (a sell TP fires at
        // price >= trigger), so it waits outside the book for a qualifying price.
        uint256 tpTrigger = 55_000 * BAZAAR_SCALE; // sell high
        uint256 tpSlippage = 500; // 5% max slippage from oracle at execution
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.TakeProfit,
                isLong: false, // closing long
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: tpTrigger,
                limitPrice: 0,
                maxSlippageBp: tpSlippage,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        BazaarTypes.Order memory o = OrderView.order(btcPair, 1);
        (uint256 tp, uint256 lp, uint256 msBp, BazaarTypes.OrderType ot) =
            (o.triggerPrice, o.limitPrice, o.maxSlippageBp, o.orderType);
        assertTrue(ot == BazaarTypes.OrderType.TakeProfit);
        assertEq(tp, tpTrigger);
        assertEq(lp, 0); // no limit price for TP
        assertEq(msBp, tpSlippage);

        // Bucket links to TP order
        (,,,,, uint256 tpOrderId,,,) = btcPair.positionBuckets(user1);
        assertEq(tpOrderId, 1);
    }

    function testCreateOrder_TakeProfit_RevertsNoPosition() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(OrderManagementLib.OrderManagementLib__NoPositionForTpSl.selector);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.TakeProfit,
                isLong: false,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 55_000 * BAZAAR_SCALE,
                limitPrice: 0,
                maxSlippageBp: 500,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_TakeProfit_RevertsSameDirection() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1); // long position

        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(OrderManagementLib.OrderManagementLib__TpSlMustBeOppositeDirection.selector);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.TakeProfit,
                isLong: true, // same as position — rejected
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 55_000 * BAZAAR_SCALE,
                limitPrice: 0,
                maxSlippageBp: 500,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    /// @dev An oversized TP is accepted, not rejected: it is capped against the live position
    ///      when it fires. Bounding it here would reject an order sized for a position its owner
    ///      means to grow into, while still missing the case that matters — a position that
    ///      shrinks after creation.
    function testCreateOrder_TakeProfit_AcceptsSizeExceedingPosition() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1); // 1 BTC long

        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.TakeProfit,
                isLong: false,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: 2 * POSITION_SIZE, // 2 BTC against a 1 BTC position
                triggerPrice: 55_000 * BAZAAR_SCALE,
                limitPrice: 0,
                maxSlippageBp: 500,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        (,,,,, uint256 tpOrderId,,,) = btcPair.positionBuckets(user1);
        assertEq(tpOrderId, 1, "oversized TP armed");
        uint256 storedSize = OrderView.order(btcPair, 1).size;
        assertEq(storedSize, 2 * POSITION_SIZE, "size stored as written; the cap applies at fire time");
    }

    /// @dev Size 0 is rejected for EVERY type, TP/SL included. Closing a whole position is
    ///      spelled with a size at or above it (type(uint256).max), which the fill path caps —
    ///      so 0 carries no meaning and is never a valid order.
    function testCreateOrder_ZeroSizeRejectedForEveryType() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1); // gives TP/SL a position to attach to
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        BazaarTypes.OrderType[4] memory types = [
            BazaarTypes.OrderType.Market,
            BazaarTypes.OrderType.StopLimit,
            BazaarTypes.OrderType.TakeProfit,
            BazaarTypes.OrderType.StopLoss
        ];
        for (uint256 i = 0; i < types.length; i++) {
            BazaarTypes.OrderType ot = types[i];
            bool isStopLimit = ot == BazaarTypes.OrderType.StopLimit;
            vm.prank(user1);
            vm.expectRevert(OrderManagementLib.OrderManagementLib__ZeroSize.selector);
            btcPair.createOrder(
                BazaarTypes.OrderSpec({
                    orderType: ot,
                    isLong: false,
                    isPostOnly: false,
                    tif: BazaarTypes.TimeInForce.GTC,
                    size: 0,
                    triggerPrice: ot == BazaarTypes.OrderType.Market ? 0 : 45_000 * BAZAAR_SCALE,
                    limitPrice: isStopLimit ? 44_000 * BAZAAR_SCALE : 0,
                    maxSlippageBp: isStopLimit ? 0 : 500,
                    expirationBlock: isStopLimit ? uint64(block.number + 100) : 0,
                    integrator: address(0)
                }),
                BazaarTypes.MatchHints(0, 0, 0, 0, 0),
                priceUpdate,
                0,
                0,
                0,
                "",
                ""
            );
        }
    }

    /// @dev type(uint256).max is the close-everything idiom. It must survive the $5 notional
    ///      check, which multiplies size by a reference price — judged on the raw number that
    ///      multiply overflows and the idiom would be uncreatable.
    function testCreateOrder_TakeProfit_AcceptsMaxUintAsClosePosition() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.TakeProfit,
                isLong: false,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: type(uint256).max,
                triggerPrice: 55_000 * BAZAAR_SCALE,
                limitPrice: 0,
                maxSlippageBp: 500,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        (,,,,, uint256 tpOrderId,,,) = btcPair.positionBuckets(user1);
        assertEq(tpOrderId, 1, "max-size TP armed");
        uint256 storedSize = OrderView.order(btcPair, 1).size;
        // The close-everything idiom is stored as the field's maximum. Any size at or above the
        // position means the same thing — the fill path caps it at the live position — so the
        // clamp is lossless, and it keeps type(uint256).max a creatable order.
        assertEq(storedSize, type(uint128).max, "clamped to the stored width; the cap applies at fire time");
    }

    /// @dev StopLoss takes the same idiom.
    function testCreateOrder_StopLoss_AcceptsMaxUintAsClosePosition() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.StopLoss,
                isLong: false,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: type(uint256).max,
                triggerPrice: 45_000 * BAZAAR_SCALE,
                limitPrice: 0,
                maxSlippageBp: 500,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        (,,,,,, uint256 slOrderId,,) = btcPair.positionBuckets(user1);
        assertEq(slOrderId, 1, "max-size SL armed");
    }

    function testCreateOrder_StopLoss_RevertsZeroTriggerPrice() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(OrderManagementLib.OrderManagementLib__ZeroTriggerPrice.selector);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.StopLoss,
                isLong: false,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: 0,
                maxSlippageBp: 100,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_StopLoss_RevertsInvalidSlippageZero() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__InvalidSlippage.selector, 0));
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.StopLoss,
                isLong: false,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 45_000 * BAZAAR_SCALE,
                limitPrice: 0,
                maxSlippageBp: 0,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    // ==================== createOrder: Margin & Multiple Orders ====================

    function testCreateOrder_MultipleOrders_CumulativeMargin() public {
        // Deposit $25,000, place two limit orders for 1 BTC each
        // Each order notional = $50,000, worst case combined = $100,000
        // IMR = 20% = $20,000
        _depositCollateral(btcPair, user1, 25_000 * BAZAAR_SCALE);
        _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        // Second order same direction — combined margin should be checked
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));
        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        // Both orders tracked
        (uint256[] memory activeOrders, uint256 count,,) = btcPair.getUserActiveLimitOrders(user1);
        assertEq(count, 2);
    }

    function testCreateOrder_MultipleOrders_RevertsExceedsMargin() public {
        // Deposit $15,000 — enough for one order but not two
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        // Second order should fail — combined IMR = $20,000 > $15,000
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));
        vm.prank(user1);
        vm.expectRevert(); // InsufficientMarginAfterOrder
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    // ==================== createOrder: Meta-Tx / Relayer Tests ====================

    function testCreateOrder_ViaRelayer() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 10 seconds;
        uint256 relayerFeeAmount = 5e16; // 0.05 USDC
        uint64 expirationBlock = uint64(block.number + 500_000);
        uint256 relayerFeeUsdc = relayerFeeAmount * USDC_SCALE / BAZAAR_SCALE;

        // The fee is pulled from the signer's wallet, so the pair needs an allowance for it.
        vm.prank(user1);
        usdc.approve(address(btcPair), relayerFeeUsdc);
        uint256 user1UsdcBefore = usdc.balanceOf(user1);

        bytes memory sig = _signCreateOrder(
            btcPair,
            USER1_PK,
            BazaarTypes.OrderType.Limit,
            0,
            BTC_SPOT_PRICE,
            0,
            POSITION_SIZE,
            true,
            false,
            expirationBlock,
            address(0),
            nonce,
            deadline,
            relayerFeeAmount
        );

        vm.prank(relayer);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: expirationBlock,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            nonce,
            deadline,
            relayerFeeAmount,
            sig,
            ""
        );

        // Order created for user1, not relayer
        address creator = OrderView.order(btcPair, 1).creator;
        assertEq(creator, user1);

        // Collateral is untouched: the fee never routes through the bucket.
        (,,, uint256 collateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(collateral, 15_000 * BAZAAR_SCALE);

        // The fee accrued to the relayer, and it came from the user's wallet.
        (uint256 owed,) = btcPair.claimableFees(relayer);
        assertEq(owed, relayerFeeAmount);
        assertEq(usdc.balanceOf(user1), user1UsdcBefore - relayerFeeUsdc);

        // Nonce incremented
        assertEq(btcPair.metaTxNonces(user1), 1);
    }

    /// @notice The relayer fee has no collateral fallback: a signer holding ample collateral but
    ///         no USDC allowance cannot have the fee taken from the bucket instead.
    function testCreateOrder_ViaRelayer_RevertsWithoutWalletAllowance() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 10 seconds;
        uint256 relayerFeeAmount = 9e17; // 0.9 USDC
        uint256 relayerFeeUsdc = relayerFeeAmount * USDC_SCALE / BAZAAR_SCALE;

        // No allowance left for the fee; the pair may not reach for the bucket instead.
        vm.prank(user1);
        usdc.approve(address(btcPair), 0);

        bytes memory sig = _signCreateOrder(
            btcPair,
            USER1_PK,
            BazaarTypes.OrderType.Limit,
            0,
            BTC_SPOT_PRICE,
            0,
            POSITION_SIZE,
            true,
            false,
            uint64(block.number + 500_000),
            address(0),
            nonce,
            deadline,
            relayerFeeAmount
        );

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(btcPair), 0, relayerFeeUsdc
            )
        );
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            nonce,
            deadline,
            relayerFeeAmount,
            sig,
            ""
        );

        // Nothing moved: no order, whole bucket, nothing owed to the relayer.
        (,,, uint256 collateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(collateral, 15_000 * BAZAAR_SCALE);
        (uint256 owed,) = btcPair.claimableFees(relayer);
        assertEq(owed, 0);
    }

    // ==================== createOrder: Integrator Tests ====================

    function testCreateOrder_WithIntegrator() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        address integratorAddr = makeAddr("integrator");

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: integratorAddr
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        address integrator = OrderView.order(btcPair, 1).integrator;
        assertEq(integrator, integratorAddr);
    }

    // ==================== createOrder: Order ID Sequencing ====================

    function testCreateOrder_OrderIdIncrementing() public {
        _depositCollateral(btcPair, user1, 30_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        // Create first order
        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE / 2,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        // Create second order
        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: false,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE / 2,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        // First order is ID 1, second is ID 2
        address creator1 = OrderView.order(btcPair, 1).creator;
        address creator2 = OrderView.order(btcPair, 2).creator;
        assertEq(creator1, user1);
        assertEq(creator2, user1);

        // Order 3 doesn't exist
        address creator3 = OrderView.order(btcPair, 3).creator;
        assertEq(creator3, address(0));
    }

    // ==================== Helper: EIP-712 Signing (cancelOrders) ====================

    function _signCancelOrders(
        BazaarPair pair,
        uint256 privateKey,
        uint256[] memory orderIds,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                MetaTxLib.CANCEL_ORDERS_TYPEHASH, keccak256(abi.encodePacked(orderIds)), nonce, deadline, relayerFee
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(pair.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ==================== cancelOrders Tests ====================

    function testCancelOrders_SingleLimitOrder() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        uint256 orderId = _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        // Verify order is active
        BazaarTypes.Order memory o = OrderView.order(btcPair, orderId);
        (address creator, uint64 canceledBlock) = (o.creator, o.canceledBlock);
        assertEq(creator, user1);
        assertEq(canceledBlock, 0);

        // Read original creationBlock + expiryBlock from storage so the assertion is exact
        BazaarTypes.Order memory os = OrderView.order(btcPair, orderId);
        (uint64 creationBlockStored, uint64 expiryBlockStored) = (os.creationBlock, os.expiryBlock);

        // Cancel it
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        vm.expectEmit(true, true, true, true, address(btcPair));
        emit BazaarTypes.OrderUpdated(
            btcPair.pairId(),
            orderId,
            user1,
            BazaarTypes.OrderUpdatePayload({
                action: BazaarTypes.OrderAction.Canceled,
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                size: POSITION_SIZE,
                filledSize: 0,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE,
                maxSlippageBp: 0,
                canceledBlock: uint64(block.number),
                filledBlock: 0,
                expiryBlock: expiryBlockStored,
                creationBlock: creationBlockStored
            })
        );

        vm.prank(user1);
        btcPair.cancelOrders(ids, 0, 0, 0, "", "");

        // Verify order is canceled (canceledBlock != 0)
        uint64 canceledBlockAfter = OrderView.order(btcPair, orderId).canceledBlock;
        assertTrue(canceledBlockAfter != 0);
    }

    function testCancelOrders_MultipleLimitOrders() public {
        _depositCollateral(btcPair, user1, 30_000 * BAZAAR_SCALE);
        // Non-crossing prices: a bid and ask at the same price would self-match on arrival.
        uint256 orderId1 = _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE / 2, BTC_SPOT_PRICE);
        uint256 orderId2 =
            _createLimitOrder(user1, USER1_PK, false, POSITION_SIZE / 2, BTC_SPOT_PRICE + 1_000 * BAZAAR_SCALE);

        uint256[] memory ids = new uint256[](2);
        ids[0] = orderId1;
        ids[1] = orderId2;

        vm.prank(user1);
        btcPair.cancelOrders(ids, 0, 0, 0, "", "");

        // Both orders should be canceled
        uint64 cb1 = OrderView.order(btcPair, orderId1).canceledBlock;
        uint64 cb2 = OrderView.order(btcPair, orderId2).canceledBlock;
        assertTrue(cb1 != 0);
        assertTrue(cb2 != 0);
    }

    function testCancelOrders_RemovedFromActiveLimitOrders() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        uint256 orderId = _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        // Verify order is in active set
        (uint256[] memory activeBefore, uint256 countBefore,,) = btcPair.getUserActiveLimitOrders(user1);
        assertEq(countBefore, 1);
        assertEq(activeBefore[0], orderId);

        // Cancel
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        vm.prank(user1);
        btcPair.cancelOrders(ids, 0, 0, 0, "", "");

        // Verify removed from active set
        (, uint256 countAfter,,) = btcPair.getUserActiveLimitOrders(user1);
        assertEq(countAfter, 0);
    }

    function testCancelOrders_RevertsNotOwner() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        uint256 orderId = _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        // user2 tries to cancel user1's order
        vm.prank(user2);
        vm.expectRevert(BazaarPair.BazaarPair__RequestorIsNotOrderOwner.selector);
        btcPair.cancelOrders(ids, 0, 0, 0, "", "");
    }

    function testCancelOrders_RevertsAlreadyCanceled() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        uint256 orderId = _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        // Cancel once
        vm.prank(user1);
        btcPair.cancelOrders(ids, 0, 0, 0, "", "");

        // Try to cancel again — should revert
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__OrderIsNotActive.selector, orderId)
        );
        btcPair.cancelOrders(ids, 0, 0, 0, "", "");
    }

    function testCancelOrders_RevertsNonExistentOrder() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 999; // doesn't exist

        // orders[999].creator == address(0) != user1, so ownership check fails first
        vm.prank(user1);
        vm.expectRevert(BazaarPair.BazaarPair__RequestorIsNotOrderOwner.selector);
        btcPair.cancelOrders(ids, 0, 0, 0, "", "");
    }

    function testCancelOrders_ViaRelayer() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        uint256 orderId = _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        uint256 nonce = btcPair.metaTxNonces(user1);
        uint256 deadline = block.timestamp + 10 seconds;
        uint256 relayerFee = 1 * BAZAAR_SCALE; // 1 USDC

        bytes memory sig = _signCancelOrders(btcPair, USER1_PK, ids, nonce, deadline, relayerFee);

        // The fee is pulled from the signer's wallet, so the pair needs an allowance for it.
        uint256 relayerFeeUsdc = relayerFee / (BAZAAR_SCALE / USDC_SCALE);
        vm.prank(user1);
        usdc.approve(address(btcPair), relayerFeeUsdc);
        uint256 user1BalBefore = usdc.balanceOf(user1);

        vm.prank(relayer);
        btcPair.cancelOrders(ids, nonce, deadline, relayerFee, sig, "");

        // Order canceled
        uint64 canceledBlock = OrderView.order(btcPair, orderId).canceledBlock;
        assertTrue(canceledBlock != 0);

        // The fee accrued to the relayer from the user's wallet; collateral is untouched.
        (uint256 owed,) = btcPair.claimableFees(relayer);
        assertEq(owed, relayerFee);
        assertEq(user1BalBefore - usdc.balanceOf(user1), relayerFeeUsdc);
        (,,, uint256 collateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(collateral, 15_000 * BAZAAR_SCALE);
    }

    /// @notice The relayer fee has no collateral fallback: with no USDC allowance the cancel
    ///         reverts and the bucket stays whole.
    function testCancelOrders_RelayerRevertsWithoutWalletAllowance() public {
        uint256 deposit = 15_000 * BAZAAR_SCALE;
        _depositCollateral(btcPair, user1, deposit);
        uint256 orderId = _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        uint256 nonce = btcPair.metaTxNonces(user1);
        uint256 deadline = block.timestamp + 10 seconds;
        uint256 relayerFee = 5e17; // 0.5 USDC (under MAX_RELAYER_FEE of 1e18)
        uint256 relayerFeeUsdc = relayerFee / (BAZAAR_SCALE / USDC_SCALE);

        bytes memory sig = _signCancelOrders(btcPair, USER1_PK, ids, nonce, deadline, relayerFee);

        // _depositCollateral approves exactly the deposit, so nothing is left for the fee.
        assertEq(usdc.allowance(user1, address(btcPair)), 0);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(btcPair), 0, relayerFeeUsdc
            )
        );
        btcPair.cancelOrders(ids, nonce, deadline, relayerFee, sig, "");

        (,,, uint256 collateral,,,,,) = btcPair.positionBuckets(user1);
        assertEq(collateral, deposit);
        assertEq(OrderView.order(btcPair, orderId).canceledBlock, 0);
    }

    function testCancelOrders_RelayerRevertsRelayerFeeExceedsMax() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        uint256 orderId = _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        uint256 nonce = btcPair.metaTxNonces(user1);
        uint256 deadline = block.timestamp + 10 seconds;
        uint256 relayerFee = 2 * BAZAAR_SCALE; // exceeds MAX_RELAYER_FEE (1e18)

        bytes memory sig = _signCancelOrders(btcPair, USER1_PK, ids, nonce, deadline, relayerFee);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(MetaTxLib.MetaTx__RelayerFeeExceedsMax.selector, relayerFee, 1e18));
        btcPair.cancelOrders(ids, nonce, deadline, relayerFee, sig, "");
    }

    /// @notice An empty id list is rejected, not treated as a no-op: with no order consumed, a
    ///         relayed cancelOrders([], …, relayerFee, sig) would still consume the signer's nonce
    ///         and pay the relayer for nothing.
    function testCancelOrders_EmptyArray_Reverts() public {
        uint256[] memory ids = new uint256[](0);

        vm.prank(user1);
        vm.expectRevert(BazaarPair.BazaarPair__ExceedsMaxCancelsPerCall.selector);
        btcPair.cancelOrders(ids, 0, 0, 0, "", "");
    }

    function testCancelOrders_CancelTPOrder_ClearsBucketRef() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        // Create TP order
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));
        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.TakeProfit,
                isLong: false,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: BTC_SPOT_PRICE + 5_000 * BAZAAR_SCALE,
                limitPrice: 0,
                maxSlippageBp: 500,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        // Verify TP order ID set on bucket
        (,,,,, uint256 tpBefore,,,) = btcPair.positionBuckets(user1);
        assertTrue(tpBefore != 0);

        // Cancel TP
        uint256[] memory ids = new uint256[](1);
        ids[0] = tpBefore;
        vm.prank(user1);
        btcPair.cancelOrders(ids, 0, 0, 0, "", "");

        // Verify TP order ID cleared on bucket
        (,,,,, uint256 tpAfter,,,) = btcPair.positionBuckets(user1);
        assertEq(tpAfter, 0);
    }

    function testCancelOrders_CancelSLOrder_ClearsBucketRef() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        // Create SL order
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));
        uint256 triggerPrice = BTC_SPOT_PRICE - 5_000 * BAZAAR_SCALE;
        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.StopLoss,
                isLong: false,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: POSITION_SIZE,
                triggerPrice: triggerPrice,
                limitPrice: 0,
                maxSlippageBp: 500,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        // Verify SL order ID set on bucket
        (,,,,,, uint256 slBefore,,) = btcPair.positionBuckets(user1);
        assertTrue(slBefore != 0);

        // Cancel SL
        uint256[] memory ids = new uint256[](1);
        ids[0] = slBefore;
        vm.prank(user1);
        btcPair.cancelOrders(ids, 0, 0, 0, "", "");

        // Verify SL order ID cleared on bucket
        (,,,,,, uint256 slAfter,,) = btcPair.positionBuckets(user1);
        assertEq(slAfter, 0);
    }

    function testCancelOrders_GasMeasurement_Single() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        uint256 orderId = _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE, BTC_SPOT_PRICE);

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;

        uint256 gasBefore = gasleft();
        vm.prank(user1);
        btcPair.cancelOrders(ids, 0, 0, 0, "", "");
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas for single cancel", gasUsed);
    }

    function testCancelOrders_GasMeasurement_Batch10() public {
        usdc.mint(user1, 100_000 * USDC_SCALE); // ensure enough balance
        _depositCollateral(btcPair, user1, 100_000 * BAZAAR_SCALE);

        // All same-side: alternating sides at one price would self-match on arrival instead of
        // resting, leaving nothing to cancel.
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; i++) {
            ids[i] = _createLimitOrder(user1, USER1_PK, true, POSITION_SIZE / 10, BTC_SPOT_PRICE);
        }

        uint256 gasBefore = gasleft();
        vm.prank(user1);
        btcPair.cancelOrders(ids, 0, 0, 0, "", "");
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas for 10 cancels", gasUsed);
    }

    // ── Exceeds MAX_CANCELS_PER_CALL ──────────────────────────────────────

    function testCancelOrders_RevertsExceedsMaxCancelsPerCall() public {
        uint256[] memory ids = new uint256[](201);
        for (uint256 i; i < 201; i++) {
            ids[i] = i + 1; // dummy ids, revert fires before ownership check
        }

        vm.expectRevert(BazaarPair.BazaarPair__ExceedsMaxCancelsPerCall.selector);
        vm.prank(user1);
        btcPair.cancelOrders(ids, 0, 0, 0, "", "");
    }

    // ==================== Per-User Order Cap Tests ====================
    //
    // Limit + StopLimit share one set, capped at MAX_ACTIVE_LIMIT_ORDERS_PER_USER. Market
    // orders are terminal within their own transaction and count against no cap. These read the
    // constant rather than its value: the cap is tuned against the exposure-sweep cost it bounds,
    // so it is expected to move.
    uint256 internal constant CAP = BazaarTypes.MAX_ACTIVE_LIMIT_ORDERS_PER_USER;

    /// @dev Create one tiny long limit order at $25,000 (half of spot) — keeps notional and
    ///      IMR low so a full cap fits under a moderate deposit. The tail hint and price
    ///      bytes are built BEFORE the prank: both make external calls, which would consume it.
    function _createSmallLimitOrder(address user) internal {
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));
        BazaarTypes.MatchHints memory tailHint = BazaarTypes.MatchHints(_bidTail(), 0, 0, 0, 0);
        vm.prank(user);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: BAZAAR_SCALE / 1000,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE / 2,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            tailHint,
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    /// @dev The current tail of the bid list — the exact predecessor hint for appending another
    ///      order at or below the worst bid price. Same-price orders queue strictly behind their
    ///      elders, so filling the cap at one price needs real hints: a zero-hint
    ///      insert walks from the head and the repair budget covers only MAX_WALK_STEPS nodes.
    function _bidTail() internal view returns (uint64 tail) {
        (uint64 cur,,,) = btcPair.book();
        while (cur != 0) {
            tail = cur;
            uint64 nxt = OrderView.order(btcPair, cur).nextInBook;
            cur = nxt;
        }
    }

    function _createSmallStopLimitOrder(address user) internal {
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));
        vm.prank(user);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.StopLimit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: BAZAAR_SCALE / 1000,
                triggerPrice: BTC_SPOT_PRICE * 2,
                limitPrice: BTC_SPOT_PRICE * 2,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_LimitCap_AcceptsExactlyCap() public {
        _depositCollateral(btcPair, user1, 50_000 * BAZAAR_SCALE);

        for (uint256 i = 0; i < CAP; i++) {
            _createSmallLimitOrder(user1);
        }

        (uint256[] memory ids,,,) = btcPair.getUserActiveLimitOrders(user1);
        assertEq(ids.length, CAP);
    }

    function testCreateOrder_LimitCap_RevertsOnePastCap() public {
        _depositCollateral(btcPair, user1, 50_000 * BAZAAR_SCALE);

        for (uint256 i = 0; i < CAP; i++) {
            _createSmallLimitOrder(user1);
        }

        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));
        vm.expectRevert(OrderManagementLib.OrderManagementLib__TooManyActiveLimitOrders.selector);
        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: BAZAAR_SCALE / 1000,
                triggerPrice: 0,
                limitPrice: BTC_SPOT_PRICE / 2,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_LimitCap_LimitAndStopLimitShareSet() public {
        _depositCollateral(btcPair, user1, 50_000 * BAZAAR_SCALE);

        // Half limits, half stop-limits — together they fill the one shared set.
        for (uint256 i = 0; i < CAP / 2; i++) {
            _createSmallLimitOrder(user1);
        }
        for (uint256 i = 0; i < CAP - CAP / 2; i++) {
            _createSmallStopLimitOrder(user1);
        }

        // One more (StopLimit) hits the same cap
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));
        vm.expectRevert(OrderManagementLib.OrderManagementLib__TooManyActiveLimitOrders.selector);
        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.StopLimit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: BAZAAR_SCALE / 1000,
                triggerPrice: BTC_SPOT_PRICE * 2,
                limitPrice: BTC_SPOT_PRICE * 2,
                maxSlippageBp: 0,
                expirationBlock: uint64(block.number + 500_000),
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_LimitCap_AfterCancelCanCreateNew() public {
        _depositCollateral(btcPair, user1, 50_000 * BAZAAR_SCALE);

        for (uint256 i = 0; i < CAP; i++) {
            _createSmallLimitOrder(user1);
        }

        // Cancel one to free a slot
        (uint256[] memory ids,,,) = btcPair.getUserActiveLimitOrders(user1);
        uint256[] memory toCancel = new uint256[](1);
        toCancel[0] = ids[0];
        vm.prank(user1);
        btcPair.cancelOrders(toCancel, 0, 0, 0, "", "");

        // Should now succeed
        _createSmallLimitOrder(user1);

        (uint256[] memory idsAfter,,,) = btcPair.getUserActiveLimitOrders(user1);
        assertEq(idsAfter.length, CAP);
    }

    function testCreateOrder_LimitCap_ExpiredOrdersAutoPruned() public {
        _depositCollateral(btcPair, user1, 50_000 * BAZAAR_SCALE);

        // Fill the cap with short-expiry orders
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));
        uint64 shortExpiry = uint64(block.number + 100);
        for (uint256 i = 0; i < CAP; i++) {
            // Hint built BEFORE the prank — its external book reads would consume it.
            BazaarTypes.MatchHints memory tailHint = BazaarTypes.MatchHints(_bidTail(), 0, 0, 0, 0);
            vm.prank(user1);
            btcPair.createOrder(
                BazaarTypes.OrderSpec({
                    orderType: BazaarTypes.OrderType.Limit,
                    isLong: true,
                    isPostOnly: false,
                    tif: BazaarTypes.TimeInForce.GTC,
                    size: BAZAAR_SCALE / 1000,
                    triggerPrice: 0,
                    limitPrice: BTC_SPOT_PRICE / 2,
                    maxSlippageBp: 0,
                    expirationBlock: shortExpiry,
                    integrator: address(0)
                }),
                tailHint,
                priceUpdate,
                0,
                0,
                0,
                "",
                ""
            );
        }

        // Roll past expiry
        vm.roll(block.number + 200);
        vm.warp(block.timestamp + 60);

        // New order succeeds — BazaarPair._cleanupExpiredLimitOrders prunes
        // expired entries from the active set before the cap check fires
        _createSmallLimitOrder(user1);

        (uint256[] memory idsAfter,,,) = btcPair.getUserActiveLimitOrders(user1);
        assertEq(idsAfter.length, 1, "only the new live order should remain");
    }

    function testCreateOrder_LimitCap_PerUserNotGlobal() public {
        _depositCollateral(btcPair, user1, 50_000 * BAZAAR_SCALE);
        _depositCollateral(btcPair, user2, 1_000 * BAZAAR_SCALE);

        // user1 fills cap
        for (uint256 i = 0; i < CAP; i++) {
            _createSmallLimitOrder(user1);
        }

        // user2 unaffected
        _createSmallLimitOrder(user2);

        (uint256[] memory u2,,,) = btcPair.getUserActiveLimitOrders(user2);
        assertEq(u2.length, 1);
    }

    function testCreateOrder_MarketOrders_NotBoundByLimitCap() public {
        _depositCollateral(btcPair, user1, 50_000 * BAZAAR_SCALE);

        for (uint256 i = 0; i < CAP; i++) {
            _createSmallLimitOrder(user1);
        }

        // Market orders are terminal within their own transaction and count against no cap:
        // creating them at a full limit-order cap succeeds, back to back.
        _createMarketOrder(user1, true, BAZAAR_SCALE / 1000, 100);
        _createMarketOrder(user1, true, BAZAAR_SCALE / 1000, 100);

        (uint256[] memory ids,,,) = btcPair.getUserActiveLimitOrders(user1);
        assertEq(ids.length, CAP, "market orders never enter the active-limit set");
    }

    // ==================== OrderUpdated Event — Non-Limit Paths ====================

    function testCreateOrder_MarketOrder_EmitsOrderUpdated() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        uint256 size = POSITION_SIZE;
        uint256 maxSlip = 100;
        // Market: triggerPrice set to currentPrice, limitPrice cleared, and expiry stamped at
        // the creation block — the order is terminal within its own transaction.
        vm.expectEmit(true, true, true, true, address(btcPair));
        emit BazaarTypes.OrderUpdated(
            btcPair.pairId(),
            1,
            user1,
            BazaarTypes.OrderUpdatePayload({
                action: BazaarTypes.OrderAction.Created,
                orderType: BazaarTypes.OrderType.Market,
                isLong: true,
                isPostOnly: false,
                size: size,
                filledSize: 0,
                triggerPrice: BTC_SPOT_PRICE,
                limitPrice: 0,
                maxSlippageBp: maxSlip,
                canceledBlock: 0,
                filledBlock: 0,
                expiryBlock: uint64(block.number),
                creationBlock: uint64(block.number)
            })
        );

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.Market,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: size,
                triggerPrice: 0,
                limitPrice: 0,
                maxSlippageBp: maxSlip,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_StopLimit_EmitsOrderUpdated() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));

        uint256 trigger = BTC_SPOT_PRICE * 110 / 100; // $55,000
        uint256 limit = BTC_SPOT_PRICE * 111 / 100; // $55,500 — buy: limit >= trigger
        uint256 size = POSITION_SIZE;
        uint64 expiry = uint64(block.number + 500_000);

        vm.expectEmit(true, true, true, true, address(btcPair));
        emit BazaarTypes.OrderUpdated(
            btcPair.pairId(),
            1,
            user1,
            BazaarTypes.OrderUpdatePayload({
                action: BazaarTypes.OrderAction.Created,
                orderType: BazaarTypes.OrderType.StopLimit,
                isLong: true,
                isPostOnly: false,
                size: size,
                filledSize: 0,
                triggerPrice: trigger,
                limitPrice: limit,
                maxSlippageBp: 0,
                canceledBlock: 0,
                filledBlock: 0,
                expiryBlock: expiry,
                creationBlock: uint64(block.number)
            })
        );

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.StopLimit,
                isLong: true,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: size,
                triggerPrice: trigger,
                limitPrice: limit,
                maxSlippageBp: 0,
                expirationBlock: expiry,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCreateOrder_TakeProfit_EmitsOrderUpdated() public {
        // TP requires an existing position — open one via storage stub
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));
        uint256 trigger = BTC_SPOT_PRICE * 110 / 100; // profit target 10% above spot, not yet reached
        uint256 slippage = 500;
        uint256 size = POSITION_SIZE;

        vm.expectEmit(true, true, true, true, address(btcPair));
        emit BazaarTypes.OrderUpdated(
            btcPair.pairId(),
            1,
            user1,
            BazaarTypes.OrderUpdatePayload({
                action: BazaarTypes.OrderAction.Created,
                orderType: BazaarTypes.OrderType.TakeProfit,
                isLong: false, // TP for a long position is a short close
                isPostOnly: false,
                size: size,
                filledSize: 0,
                triggerPrice: trigger,
                limitPrice: 0,
                maxSlippageBp: slippage,
                canceledBlock: 0,
                filledBlock: 0,
                expiryBlock: type(uint64).max, // NEVER_EXPIRE_BLOCK
                creationBlock: uint64(block.number)
            })
        );

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.TakeProfit,
                isLong: false,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: size,
                triggerPrice: trigger,
                limitPrice: 0,
                maxSlippageBp: slippage,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );
    }

    function testCancelOrders_TakeProfit_EmitsOrderUpdated() public {
        _depositCollateral(btcPair, user1, 15_000 * BAZAAR_SCALE);
        _simulateOpenPosition(user1);

        bytes[] memory priceUpdate = _createBtcPriceUpdate(uint64(block.timestamp));
        uint256 trigger = BTC_SPOT_PRICE * 110 / 100;
        uint256 slippage = 500;
        uint256 size = POSITION_SIZE;

        vm.prank(user1);
        btcPair.createOrder(
            BazaarTypes.OrderSpec({
                orderType: BazaarTypes.OrderType.TakeProfit,
                isLong: false,
                isPostOnly: false,
                tif: BazaarTypes.TimeInForce.GTC,
                size: size,
                triggerPrice: trigger,
                limitPrice: 0,
                maxSlippageBp: slippage,
                expirationBlock: 0,
                integrator: address(0)
            }),
            BazaarTypes.MatchHints(0, 0, 0, 0, 0),
            priceUpdate,
            0,
            0,
            0,
            "",
            ""
        );

        // Pre-cancel: bucket has takeProfitOrderId set
        (,,,,, uint256 tpBefore,,,) = btcPair.positionBuckets(user1);
        assertEq(tpBefore, 1);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.expectEmit(true, true, true, true, address(btcPair));
        emit BazaarTypes.OrderUpdated(
            btcPair.pairId(),
            1,
            user1,
            BazaarTypes.OrderUpdatePayload({
                action: BazaarTypes.OrderAction.Canceled,
                orderType: BazaarTypes.OrderType.TakeProfit,
                isLong: false,
                isPostOnly: false,
                size: size,
                filledSize: 0,
                triggerPrice: trigger,
                limitPrice: 0,
                maxSlippageBp: slippage,
                canceledBlock: uint64(block.number),
                filledBlock: 0,
                expiryBlock: type(uint64).max,
                creationBlock: uint64(block.number)
            })
        );

        vm.prank(user1);
        btcPair.cancelOrders(ids, 0, 0, 0, "", "");

        // Post-cancel: bucket pointer cleared
        (,,,,, uint256 tpAfter,,,) = btcPair.positionBuckets(user1);
        assertEq(tpAfter, 0);
    }

    // ==================== PositionBucketUpdated Event ====================

    function testDepositCollateral_EmitsPositionBucketUpdated() public {
        uint256 depositAmount = 1_000 * BAZAAR_SCALE;

        vm.prank(user1);
        usdc.approve(address(btcPair), type(uint256).max);

        // Fresh deposit: pre-state is all zero, post-state has collateral set.
        // The IMR/MMR fields come from the pair's marginRequirements at emit time.
        (uint256 imrBp, uint256 mmrBp,,,) = btcPair.marginRequirements();

        vm.expectEmit(true, true, true, true, address(btcPair));
        emit BazaarTypes.PositionBucketUpdated(
            btcPair.pairId(),
            user1,
            false, // isLong (default)
            0, // size
            0, // entryValue
            depositAmount, // collateral after deposit
            0, // entryFundingIndex
            0, // globalFundingIndex (currentFundingIndex)
            imrBp,
            mmrBp,
            0 // entryMmrBp
        );

        vm.prank(user1);
        btcPair.depositCollateral(depositAmount, 0, 0, 0, "", "");
    }

    function testWithdrawCollateral_EmitsPositionBucketUpdated() public {
        uint256 depositAmount = 1_000 * BAZAAR_SCALE;
        uint256 withdrawAmount = 400 * BAZAAR_SCALE;
        _depositCollateral(btcPair, user1, depositAmount);

        (uint256 imrBp, uint256 mmrBp,,,) = btcPair.marginRequirements();

        vm.expectEmit(true, true, true, true, address(btcPair));
        emit BazaarTypes.PositionBucketUpdated(
            btcPair.pairId(), user1, false, 0, 0, depositAmount - withdrawAmount, 0, 0, imrBp, mmrBp, 0
        );

        bytes[] memory emptyPriceUpdate = new bytes[](0);
        vm.prank(user1);
        btcPair.withdrawCollateral(withdrawAmount, emptyPriceUpdate, 0, 0, 0, "");
    }
}

#!/usr/bin/env bash
# Writes the ABIs an indexer or a frontend needs to $ABI_DIR (default abi/) from a finished
# `forge build`, each as a plain JSON array.
#
# BazaarPair's compiled ABI omits the events and errors of the external libraries it links. Those
# run by DELEGATECALL, so their logs come from the pair's address — fills, orders, positions,
# collateral, liquidations, ADL, termination — and their reverts surface from the pair's calls.
# The exported BazaarPair.json appends them. The libraries are read from the pair artifact's link
# references, so a newly linked library is picked up without editing this script.
set -euo pipefail

OUT_DIR="${OUT_DIR:-out}"
ABI_DIR="${ABI_DIR:-abi}"

artifact() { printf '%s/%s.sol/%s.json' "$OUT_DIR" "$1" "$1"; }

mkdir -p "$ABI_DIR"

for name in BazaarFactory BazaarPairTerminator BazaarOracle BazaarPairLens; do
    jq '.abi' "$(artifact "$name")" > "$ABI_DIR/$name.json"
done

pair="$(artifact BazaarPair)"
libs=()
while IFS= read -r lib; do
    libs+=("$(artifact "$lib")")
done < <(jq -r '.deployedBytecode.linkReferences | to_entries[] | .value | keys[]' "$pair")

# An event or error is identified by its canonical signature — the name and parameter types, with
# tuples expanded — which is what its topic0 or selector hashes. Entries the pair already declares
# are kept once.
jq -s '
  def canon:
    if (.type | startswith("tuple"))
    then "(" + ([.components[] | canon] | join(",")) + ")" + (.type | ltrimstr("tuple"))
    else .type end;
  def sig: .type + " " + .name + "(" + ([.inputs[] | canon] | join(",")) + ")";
  (.[0].abi + [.[1:][] | .abi[] | select(.type == "event" or .type == "error")])
  | reduce .[] as $e ({seen: {}, abi: []};
      if ($e.type == "event" or $e.type == "error") then
        ($e | sig) as $k
        | if .seen[$k] then . else .seen[$k] = true | .abi += [$e] end
      else .abi += [$e] end)
  | .abi
' "$pair" "${libs[@]}" > "$ABI_DIR/BazaarPair.json"

echo "wrote $ABI_DIR/{BazaarPair,BazaarFactory,BazaarPairTerminator,BazaarOracle,BazaarPairLens}.json"

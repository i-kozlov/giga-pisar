#!/bin/sh
# giga-dict on a throwaway file: add/merge/conflict/remove/broken file/parallel adds.
# Usage: test-giga-dict.sh BINARY WORKDIR
set -eu
bin=$1
file=$2/dictionary.json
g() { "$bin" --file "$file" "$@"; }
want() { [ "$1" = "$2" ] || { echo "FAIL $3: got «$1», want «$2»"; exit 1; }; }

g add --variant "опен эй ай" --variant "open ai" --replacement OpenAI --note компания
want "$(g test 'спроси опен эй ай')" "спроси OpenAI" "add"
if g add --variant "open ai" --replacement Other 2>/dev/null; then echo "FAIL conflict accepted"; exit 1; fi
g add --variant "OPEN AI" --replacement OpenAI 2>/dev/null
want "$(g list | wc -l | tr -d ' ')" "1" "same variant is a no-op"

# A different note makes a separate rule; the note is kept.
g add --variant "оупен эй ай" --replacement OpenAI --note "вторая тема"
want "$(g list | wc -l | tr -d ' ')" "2" "different note, separate rule"
g list | grep -q "# вторая тема" || { echo "FAIL note lost"; exit 1; }
g add --variant "оупенэйай" --replacement OpenAI --note компания
want "$(g list | sed -n 1p)" "1. опен эй ай, open ai, оупенэйай → OpenAI  # компания" "same note merges"

# remove drops the variant from every rule that has it.
printf '%s' '{"version": 1, "rules": [
  {"variants": ["Кот", "киса"], "replacement": "Cat", "note": "один"},
  {"variants": ["кот"], "replacement": "Cat", "note": "два"}]}' > "$file"
g remove кот
want "$(g test 'кот и киса')" "кот и Cat" "remove from all rules"
want "$(g list)" "1. киса → Cat  # один" "empty rule dropped, others kept"
if g remove кот 2>/dev/null; then echo "FAIL removing a missing variant succeeded"; exit 1; fi

# A broken file is never overwritten.
printf '%s' '{"version": 1, "rules": [' > "$file"
if g add --variant x --replacement y 2>/dev/null; then echo "FAIL broken file overwritten"; exit 1; fi
want "$(cat "$file")" '{"version": 1, "rules": [' "broken file untouched"

# Stray arguments are errors, not silently ignored.
if g list extra 2>/dev/null; then echo "FAIL list accepted an argument"; exit 1; fi

# Parallel adds do not lose each other.
parallel=$2/parallel.json
i=1
while [ $i -le 20 ]; do "$bin" --file "$parallel" add --variant "слово$i" --replacement "W$i" & i=$((i + 1)); done
wait
want "$("$bin" --file "$parallel" list | wc -l | tr -d ' ')" "20" "parallel adds"
echo "PASS giga-dict: add, merge by note, conflict, remove from all rules, broken file, parallel adds"

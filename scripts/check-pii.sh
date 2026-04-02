#!/bin/bash
# Pre-commit hook: check for personal info leaks
# Scans tracked files for hardcoded usernames, paths, hostnames

PATTERNS='/home/[a-z]+/|/Users/[a-z]+/'

found=0
while IFS= read -r file; do
    if grep -nE "$PATTERNS" "$file" 2>/dev/null; then
        echo "^^^ Found in: $file"
        found=1
    fi
done < <(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(sh|md|yaml|yml)$|Makefile')

if [ "$found" -eq 1 ]; then
    echo ""
    echo "ERROR: Personal paths detected. Replace with generic paths before committing."
    exit 1
fi
exit 0

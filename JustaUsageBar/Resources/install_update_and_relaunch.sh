#!/bin/sh
set -u

if [ "$#" -ne 6 ]; then
    exit 64
fi

app_pid="$1"
brew_path="$2"
cask_token="$3"
app_path="$4"
failure_path="$5"
failure_kind="$6"
log_path="${failure_path}.log"

attempt=0
while kill -0 "$app_pid" 2>/dev/null && [ "$attempt" -lt 100 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
done

if kill -0 "$app_pid" 2>/dev/null; then
    {
        printf '%s\n' "$failure_kind"
        printf '%s\n' "Usagebar could not quit the old version, so the update was not installed."
    } > "$failure_path"
    rm -f "$log_path"
    /usr/bin/open "$app_path" >/dev/null 2>&1
    exit 1
fi

if HOMEBREW_NO_AUTO_UPDATE=1 "$brew_path" upgrade --cask "$cask_token" > "$log_path" 2>&1; then
    status=0
    rm -f "$failure_path"
else
    status=$?
    {
        printf '%s\n' "$failure_kind"
        /usr/bin/tail -n 6 "$log_path"
    } > "$failure_path"
fi

rm -f "$log_path"
/usr/bin/open "$app_path" >/dev/null 2>&1
exit "$status"

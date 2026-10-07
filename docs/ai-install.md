# Installing AiTerm: steps for an AI agent

You are a coding agent (Claude Code, Codex or similar) and someone asked you to set up AiTerm on
their Mac. This page installs the latest **release**. Do not clone the repository or build from
source.

Work through the steps in order. Run each check and show the person what it found. Where a step
says **ask**, wait for a yes before you go on. Where it says **the person does this**, tell them
exactly what to click, then wait until they say it's done. Some steps can't be scripted: macOS and
iTerm2 only accept those clicks from a person.

## 1. Check the requirements

```sh
sw_vers -productVersion        # must be 26 or newer
ls -d /Applications/iTerm.app  # iTerm2
ls -d /Applications/AiTerm.app # must NOT exist yet (see below)
for c in python3.14 python3.13 python3.12 python3.11 python3; do command -v $c && $c --version; done
command -v brew                # Homebrew, if they have it
```

- **macOS older than 26:** stop. AiTerm does not run there.
- **AiTerm is already installed:** stop. Tell the person to use *AiTerm › Check for Updates…*,
  which replaces the app safely. Copying over an existing bundle merges the old files with the new
  ones and breaks its signature.
- **No iTerm2:** **ask** before you install it.
- **No Python 3.11 or newer** (macOS's own `/usr/bin/python3` is 3.9 and does not count):
  **ask** before you install it. AiTerm finds Homebrew's and python.org's interpreters by itself;
  it only needs Python to run, not to install.

To install what's missing:

- **With Homebrew:** `brew install --cask iterm2` and `brew install python`.
- **Without Homebrew:** don't install Homebrew yourself. Its installer asks for an admin
  password. Let the person choose:
  - install Homebrew from <https://brew.sh> in their own terminal, then use the commands above; or
  - download the installers themselves: iTerm2 from <https://iterm2.com/downloads.html> (unzip it
    and drag it to Applications), and Python from <https://www.python.org/downloads/macos/> (the
    `.pkg` installer).

  Then run the checks again.

## 2. Download, verify and copy the app

This takes the DMG from the latest GitHub release and checks it against the SHA-256 digest that
GitHub publishes for it. Only then does it copy the app to `/Applications`. It uses no Python, and
reads the release with macOS's own `plutil`. Run it as one command: many agents' shells don't keep
variables from one call to the next. The parentheses keep `set -e` and `exit` from closing a shell
you keep open.

```sh
(
set -euo pipefail
dir="${TMPDIR:-/tmp}/aiterm-install"; rm -rf "$dir"; mkdir -p "$dir"
curl -fsSL -o "$dir/release.json" https://api.github.com/repos/dhondtlaurens/aiterm/releases/latest
name=$(plutil -extract assets.0.name raw -o - "$dir/release.json")
url=$(plutil -extract assets.0.browser_download_url raw -o - "$dir/release.json")
digest=$(plutil -extract assets.0.digest raw -o - "$dir/release.json")
[[ $name == *.dmg && $digest == sha256:* ]] || { echo "Unexpected release asset: $name" >&2; exit 1; }
curl -fL -o "$dir/AiTerm.dmg" "$url"
echo "${digest#sha256:}  $dir/AiTerm.dmg" | shasum -a 256 -c || { echo "Checksum mismatch: not installing." >&2; exit 1; }
mnt=$(hdiutil attach -nobrowse -readonly "$dir/AiTerm.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')
[[ -d $mnt/AiTerm.app ]] || { echo "AiTerm.app not found in the DMG." >&2; exit 1; }
ditto "$mnt/AiTerm.app" /Applications/AiTerm.app
hdiutil detach "$mnt"
echo "Installed /Applications/AiTerm.app"
)
```

It must end with `Installed /Applications/AiTerm.app`. If it stops earlier, nothing was installed.
Show the person the error and stop. Never work around a checksum mismatch. Newer macOS versions
print a deprecation warning for `hdiutil attach`; it's harmless.

## 3. Let macOS open it

The release is signed with the maintainer's own certificate, not an Apple Developer ID. macOS
blocks such apps when they carry the download flag, and lists them under *Open Anyway* instead. A
file that `curl` downloads usually has no flag, but clear it anyway. A flagged app also runs from
a temporary copy, and in that case AiTerm skips the Claude status line:

```sh
xattr -dr com.apple.quarantine /Applications/AiTerm.app
codesign --verify --deep --strict /Applications/AiTerm.app && echo signature ok
```

`spctl` rejects the app ("origin=AiTerm Release"), and that's expected for a self-signed app. It
doesn't stop the app from opening.

If macOS still says the app can't be opened when it launches in step 5, **the person does this:**
*System Settings › Privacy & Security*, scroll to the message about AiTerm, click *Open Anyway* and
confirm.

## 4. Turn on iTerm2's Python API

AiTerm controls iTerm2 through iTerm2's Python API, which is off by default.

- **iTerm2 is not running** (`pgrep -x iTerm2` prints nothing): switch it on yourself:
  `defaults write com.googlecode.iterm2 EnableAPIServer -bool true`.
- **iTerm2 is running:** don't quit it, because you may be running inside it. **The person does
  this:** *iTerm2 › Settings › General › Magic › Enable Python API*, then confirm the dialog.

## 5. Launch AiTerm

```sh
open /Applications/AiTerm.app
```

**The person does this:** iTerm2 asks once whether AiTerm may use its API. Click *Allow*. Until
they do, the sidebar shows "Waiting for iTerm2…".

## 6. Hand over

Tell the person the following. Don't do any of it for them:

- **Agent status needs hooks.** In *AiTerm › Settings › Agents*, press **Install** on the card for
  each agent they use (Claude Code, Codex, Grok Build, PI). AiTerm writes those hooks itself and
  keeps a backup of every file it changes. Don't edit `~/.claude/settings.json`, `~/.codex/` or
  `~/.grok/` by hand for this.
- **Jira, GitLab and GitHub** credentials go in *Settings › Integrations*. AiTerm stores them in
  the Keychain.
- **Codex runs without approvals.** AiTerm starts new Codex tasks with
  `--dangerously-bypass-approvals-and-sandbox`. The New Task sheet shows the command before it
  runs.
- **Updates** come through *AiTerm › Check for Updates…*.

Last, remove the download: `rm -rf "${TMPDIR:-/tmp}/aiterm-install"`.

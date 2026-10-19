#!/bin/bash
# Install.command — one-time setup for Holly Share. Double-click it.
# Installs Homebrew (if needed) and the three tools holly-share.sh uses.

cd "$(dirname "$0")" || exit 1
echo "Holly Share setup"
echo

find_brew() {
  for d in /opt/homebrew/bin /usr/local/bin; do
    if [ -x "$d/brew" ]; then PATH="$d:$PATH"; fi
  done
  command -v brew >/dev/null
}

if ! find_brew; then
  echo "Homebrew isn't installed. It's the free tool that installs everything else (https://brew.sh)."
  read -r -p "Install it now? It will ask for your Mac password. [y/N] " answer
  case "$answer" in
    [yY]*) /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" ;;
    *)     echo "Setup stopped. Nothing was installed."; exit 1 ;;
  esac
  find_brew || { echo "Homebrew didn't install. See https://brew.sh"; exit 1; }
fi

echo "Installing ffmpeg, mediamtx and qrencode..."
brew install ffmpeg mediamtx qrencode || { echo "brew install failed — see the messages above."; exit 1; }

chmod +x holly-share.sh "Start Holly Share.command"
echo
echo "Done. Double-click \"Start Holly Share.command\" whenever you want to share the stream."

#!/usr/bin/env bash
# Sets up a new computer with the latest Linux Mint (22 and later; Ubuntu 24.04
# and later too) with the programs of the old one: tools, programming languages
# and libraries, R with RStudio and Shiny Server, LaTeX, Docker, desktop apps and
# games, and apps from their makers (VS Code, Chrome, Edge, Slack, Zoom, Dropbox,
# ...), from apt repositories and .deb files, never from Flatpak. It goes one
# step at a time, shows what the step installs and asks (y) before installing
# it; a step that fails does not stop the others. At the end it lists what failed
# and what is left to do by hand.
#   new_machine.sh          asks before each step
#   new_machine.sh --yes    every step, without asking
#   new_machine.sh --list   only shows the steps and what they install

yes=0; list=0
for arg in "$@"; do
  case "$arg" in
    --yes)     yes=1 ;;
    --list)    list=1 ;;
    -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    *)         echo "Unknown option: $arg (see --help)"; exit 1 ;;
  esac
done

red=$'\e[31m'; yellow=$'\e[33m'; green=$'\e[32m'; bold=$'\e[1m'; reset=$'\e[0m'

# Linux Mint has its own release names and numbers (zena, 22.3); CRAN, Posit and
# Microsoft publish for the Ubuntu release Mint is built on (noble, 24.04)
[ -r /etc/os-release ] && . /etc/os-release
codename=${UBUNTU_CODENAME:-}
ubuntu_version=""
if [ -r /etc/upstream-release/lsb-release ]; then
  ubuntu_version=$(. /etc/upstream-release/lsb-release && echo "${DISTRIB_RELEASE:-}")
elif [ "${ID:-}" = ubuntu ]; then
  codename=${codename:-${VERSION_CODENAME:-}}
  ubuntu_version=${VERSION_ID:-}
fi
if [ -z "$codename" ] || [ -z "$ubuntu_version" ] || ! command -v apt-get > /dev/null; then
  echo "This is for Linux Mint or Ubuntu (found: ${PRETTY_NAME:-unknown})"; exit 1
fi

tools=(htop bmon terminator tmux ack git git-lfs gh git-cola meld subversion curl wget unzip jq rclone
  ffmpeg imagemagick graphicsmagick xvfb openssh-server)
# lm-sensors, alsa-utils, pciutils and fio are for hwrt.sh and disk_speed.sh
system_tools=(lm-sensors alsa-utils pciutils fio smartmontools nvme-cli intel-gpu-tools mesa-utils
  vulkan-tools vainfo cpu-x stress speedtest-cli)
programming=(build-essential cmake default-jdk sbcl clisp nodejs npm cargo rustc postgresql mysql-client
  python3-dev python3-pip python3-venv python3-setuptools virtualenv pipx
  liblzma-dev libbz2-dev libffi-dev libncurses-dev xz-utils libxmlsec1-dev
  libopenblas-dev liblapack-dev libmpfr-dev libgsl-dev libgmp-dev libfftw3-dev
  libpng-dev libjpeg-dev tk-dev libproj-dev libgdal-dev libudunits2-dev libx11-dev libglu1-mesa-dev freeglut3-dev
  libssl-dev libcurl4-openssl-dev libxml2-dev libxslt1-dev libyaml-dev libsqlite3-dev libpq-dev libpq5
  libmysqlclient-dev libreadline-dev libpcap-dev zlib1g-dev libsndfile1-dev libxss1 libxss-dev
  libstdc++6 libstdc++5 lib32z1 libayatana-appindicator3-1)
python_version=3.12
# R, and what the R packages of the repositories in ~/GitHub need to compile (worked out with pak)
r_apt=(r-base r-base-dev default-jdk pandoc cmake libcurl4-openssl-dev libssl-dev libxml2-dev libicu-dev
  libfontconfig1-dev libfreetype6-dev libharfbuzz-dev libfribidi-dev libpng-dev libjpeg-dev libtiff-dev
  libwebp-dev libgit2-dev libuv1-dev libglpk-dev libgdal-dev libx11-dev libglu1-mesa-dev zlib1g-dev)
r_packages=(shiny rmarkdown rJava SparseM rgl)
latex=(texlive texlive-latex-extra texlive-xetex texlive-luatex texlive-science texlive-pictures
  texlive-bibtex-extra texlive-lang-greek texlive-fonts-extra texmaker)
docker=(docker.io docker-compose-v2 docker-buildx)
apps=(calibre cheese thunderbird lyx vlc audacity gimp inkscape pdfarranger gcolor3 simplescreenrecorder
  virtualbox virtualbox-ext-pack ttf-mscorefonts-installer)
games=(hedgewars neverball aisleriot)
network=(nmap arp-scan wireshark aircrack-ng wifite macchanger)
security=(clamav clamav-daemon rkhunter chkrootkit debsums)
vscode_extensions=(anthropic.claude-code davidanson.vscode-markdownlint intellicad.icad-lisp
  james-yu.latex-workshop kakumei.php-xdebug mattn.lisp mechatroner.rainbow-csv
  ms-azuretools.vscode-containers ms-python.debugpy ms-python.python ms-python.vscode-pylance
  ms-python.vscode-python-envs ms-toolsai.jupyter ms-toolsai.jupyter-keymap ms-toolsai.jupyter-renderers
  ms-toolsai.vscode-jupyter-cell-tags ms-toolsai.vscode-jupyter-slideshow ms-vscode-remote.remote-containers
  ms-vscode-remote.remote-ssh ms-vscode-remote.remote-ssh-edit ms-vscode.makefile-tools ms-vscode.powershell
  ms-vscode.remote-explorer ms-vscode.remote-server qingpeng.common-lisp reditorsupport.r
  reditorsupport.r-syntax tomoki1207.pdf xdebug.php-debug)

# a line of 80 # characters, between the steps
separator() { printf '#%.0s' {1..80}; printf '\n'; }

# anything but y/yes is no
yes_no() {
  local answer
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# apt without questions (the few it would ask are answered first with preseed),
# waiting up to 2 minutes while the Update Manager is using apt
apt_get() { sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 "$@"; }

# an answer to a question a package asks while installing (debconf)
preseed() { echo "$1" | sudo debconf-set-selections; }

# installs the packages this release has and names the ones it does not, as one
# missing name would make apt install none of them
apt_install() {
  local package available=()
  for package in "$@"; do
    if apt-cache show "$package" > /dev/null 2>&1; then
      available+=("$package")
    else
      echo "${yellow}Not available on this release, skipped: $package${reset}"
    fi
  done
  [ ${#available[@]} -eq 0 ] && return 0
  apt_get install -y "${available[@]}"
}

# downloads a .deb from its maker and installs it with what it depends on
install_deb() {  # name, address
  curl -fL --progress-bar -o "$tmp/$1.deb" "$2" && chmod 644 "$tmp/$1.deb" &&
    apt_get install -y "$tmp/$1.deb"
}

# whether an apt repository is set up already (by an earlier run, or by the app itself)
has_repository() {
  grep -rqs --include='*.list' --include='*.sources' "^[^#]*$1" /etc/apt/sources.list /etc/apt/sources.list.d/
}

# for a step with several apps: installs each one, even after one fails, and
# keeps the names of the ones that failed in failed_apps
each() {  # name:function ...
  local entry
  for entry in "$@"; do
    echo "${bold}${entry%%:*}${reset}"
    "${entry#*:}" || failed_apps+="${failed_apps:+, }${entry%%:*}"
  done
  [ -z "$failed_apps" ]
}

# downloads are kept here until the end; apt reads the .deb files as its own
# user (_apt), so the folder is readable by all
tmp=$(mktemp -d)
chmod 755 "$tmp"
trap 'rm -rf "$tmp"' EXIT

updates_step() { apt_get full-upgrade -y; }

nvidia_step() {
  # the driver Mint's Driver Manager recommends
  sudo ubuntu-drivers install || return
  apt_install nvidia-settings || return
  # Coolbits 4 lets nvidia-settings set the fan speed
  sudo nvidia-xconfig --cool-bits=4 || return
  restart=1
}

tools_step() { apt_install "${tools[@]}" && git lfs install; }

system_tools_step() { apt_install "${system_tools[@]}"; }

programming_step() { apt_install "${programming[@]}"; }

# pyenv in ~/.pyenv, without changing ~/.bashrc, so the system Python stays the default
pyenv_step() {
  command -v git > /dev/null || apt_install git || return
  if [ ! -d "$HOME/.pyenv" ]; then
    curl -fsSL https://pyenv.run | bash || return
  fi
  "$HOME/.pyenv/bin/pyenv" install --skip-existing "$python_version"
}

r_step() {
  local url=https://cloud.r-project.org/bin/linux/ubuntu repos packages
  if ! has_repository /bin/linux/ubuntu; then
    curl -fsSL -o "$tmp/cran.asc" "$url/marutter_pubkey.asc" || return
    sudo install -D -m 644 "$tmp/cran.asc" /etc/apt/keyrings/cran_ubuntu_key.asc || return
    echo "deb [signed-by=/etc/apt/keyrings/cran_ubuntu_key.asc] $url $codename-cran40/" |
      sudo tee /etc/apt/sources.list.d/cran-r.list > /dev/null
    apt_get update || return
  fi
  apt_install "${r_apt[@]}" || return
  sudo R CMD javareconf
  # ready-built packages from Posit for this Ubuntu release, if it has them (much quicker)
  repos="https://packagemanager.posit.co/cran/__linux__/$codename/latest"
  curl -fsI "$repos/src/contrib/PACKAGES" > /dev/null || repos=https://cloud.r-project.org
  packages=$(printf '"%s", ' "${r_packages[@]}")
  # into the library of all users, as Shiny Server runs the apps as its own user (shiny)
  sudo Rscript -e "
    options(repos = c(CRAN = '$repos'), HTTPUserAgent = sprintf('R/%s R (%s)', getRversion(),
      paste(getRversion(), R.version[['platform']], R.version[['arch']], R.version[['os']])))
    packages <- c(${packages%, })
    lib <- '/usr/local/lib/R/site-library'
    dir.create(lib, recursive = TRUE, showWarnings = FALSE)
    install.packages(packages, lib = lib)
    missing <- packages[!nzchar(vapply(packages, function(p) system.file(package = p), ''))]
    if (length(missing)) stop('not installed: ', paste(missing, collapse = ', '))"
}

# Posit builds RStudio and its servers on Ubuntu 22.04 and 20.04, for those
# releases and the ones after them
rstudio_step() { install_deb rstudio https://rstudio.org/download/latest/stable/desktop/jammy/rstudio-latest-amd64.deb; }

shiny_server_app() {
  local version
  version=$(curl -fsSL https://download3.rstudio.org/ubuntu-20.04/x86_64/VERSION) || return
  install_deb shiny-server "https://download3.rstudio.org/ubuntu-20.04/x86_64/shiny-server-$version-amd64.deb"
}
rstudio_server_app() { install_deb rstudio-server https://rstudio.org/download/latest/stable/server/jammy/rstudio-server-latest-amd64.deb; }

servers_step() {
  if ! command -v R > /dev/null; then
    echo "${red}The servers need R: install it with the R step first${reset}"; return 1
  fi
  each "Shiny Server:shiny_server_app" "RStudio Server:rstudio_server_app"
}

latex_step() { apt_install "${latex[@]}"; }

docker_step() {
  apt_install "${docker[@]}" || return
  # docker without sudo
  sudo usermod -aG docker "$USER"
  relogin=1
}

apps_step() {
  preseed "virtualbox-ext-pack virtualbox-ext-pack/license boolean true"
  preseed "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula boolean true"
  apt_install "${apps[@]}" || return
  # USB devices in VirtualBox machines
  sudo usermod -aG vboxusers "$USER"
  relogin=1
}

# Valve's .deb, as on the old computer (Ubuntu's steam-installer clashes with it):
# it adds Valve's repository, which has the 32-bit (i386) libraries Steam needs
steam_app() {
  sudo dpkg --add-architecture i386 || return
  install_deb steam https://repo.steampowered.com/steam/archive/stable/steam_latest.deb &&
    apt_get update && apt_install steam-libs-amd64 steam-libs-i386:i386
}
games_apt() { apt_install "${games[@]}"; }
games_step() { each "Steam:steam_app" "${games[*]}:games_apt"; }

vscode_app() {
  local extension
  # the .deb adds Microsoft's repository when it is told to, so VS Code updates with the system
  preseed "code code/add-microsoft-repo boolean true"
  install_deb code "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64" || return
  for extension in "${vscode_extensions[@]}"; do
    code --install-extension "$extension" > /dev/null ||
      echo "${yellow}VS Code extension not installed: $extension${reset}"
  done
}

sublime_app() {
  if ! has_repository download.sublimetext.com; then
    curl -fsSL -o "$tmp/sublime.asc" https://download.sublimetext.com/sublimehq-pub.gpg || return
    sudo install -D -m 644 "$tmp/sublime.asc" /etc/apt/keyrings/sublimehq-pub.asc || return
    printf 'Types: deb\nURIs: https://download.sublimetext.com/\nSuites: apt/stable/\nSigned-By: /etc/apt/keyrings/sublimehq-pub.asc\n' |
      sudo tee /etc/apt/sources.list.d/sublime-text.sources > /dev/null
    apt_get update || return
  fi
  apt_install sublime-text
}

editors_step() { each "VS Code:vscode_app" "Sublime Text:sublime_app"; }

# both .deb files add their maker's repository, so the browsers update with the system
chrome_app() { install_deb google-chrome https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; }
edge_app()   { install_deb microsoft-edge "https://go.microsoft.com/fwlink?linkid=2149051"; }
browsers_step() { each "Google Chrome:chrome_app" "Microsoft Edge:edge_app"; }

# the newest .deb of each, from its maker
slack_app()   { install_deb slack "https://slack.com/api/desktop.latestRelease?arch=x64&variant=deb&redirect=true"; }
discord_app() { install_deb discord "https://discord.com/api/download?platform=linux&format=deb"; }
zoom_app()    { install_deb zoom https://zoom.us/client/latest/zoom_amd64.deb; }
viber_app()   { install_deb viber https://download.cdn.viber.com/cdn/desktop/Linux/viber.deb; }
chat_step() { each "Slack:slack_app" "Discord:discord_app" "Zoom:zoom_app" "Viber:viber_app"; }

# Linux Mint has Dropbox in its own repository; elsewhere, Dropbox's .deb
dropbox_app() {
  if apt-cache show dropbox > /dev/null 2>&1; then
    apt_install dropbox
  else
    install_deb dropbox https://linux.dropbox.com/packages/ubuntu/dropbox_2024.04.17_amd64.deb
  fi
}

insync_app() {
  if ! has_repository apt.insync.io; then
    curl -fsSL -o "$tmp/insync.asc" https://apt.insync.io/insynchq.gpg || return
    sudo install -D -m 644 "$tmp/insync.asc" /etc/apt/keyrings/insynchq.asc || return
    echo "deb [signed-by=/etc/apt/keyrings/insynchq.asc] https://apt.insync.io/ubuntu $codename non-free contrib" |
      sudo tee /etc/apt/sources.list.d/insync.list > /dev/null
    apt_get update || return
  fi
  apt_install insync
}

# Surfshark's own installer: adds its repository and installs the app
surfshark_app() {
  curl -fsSL -o "$tmp/surfshark.sh" https://downloads.surfshark.com/linux/debian-install.sh && sh "$tmp/surfshark.sh"
}

files_step() { each "Dropbox:dropbox_app" "Insync:insync_app" "Surfshark:surfshark_app"; }

# the .deb adds TeamViewer's repository
teamviewer_step() { install_deb teamviewer https://download.teamviewer.com/download/linux/teamviewer_amd64.deb; }

# Microsoft's repository for this Ubuntu release
powershell_step() {
  install_deb packages-microsoft-prod "https://packages.microsoft.com/config/ubuntu/$ubuntu_version/packages-microsoft-prod.deb" &&
    apt_get update && apt_install powershell
}

aws_step() {
  command -v unzip > /dev/null || apt_install unzip || return
  curl -fsSL -o "$tmp/awscli.zip" https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip &&
    unzip -q -o "$tmp/awscli.zip" -d "$tmp" && sudo "$tmp/aws/install" --update || return
  install_deb session-manager-plugin https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb
}

# iSpy's installer, which asks its own questions
agentdvr_step() {
  curl -fsSL -o "$tmp/agentdvr.sh" https://raw.githubusercontent.com/ispysoftware/agent-install-scripts/main/v3/install.sh &&
    bash "$tmp/agentdvr.sh"
}

aftershot_step() { install_deb aftershot https://dwnld.aftershotpro.com/updates/v3/AfterShotPro3.deb; }

network_step() {
  # Wireshark captures as your user (in the wireshark group); macchanger does not
  # change the MAC address by itself at every connection
  preseed "wireshark-common wireshark-common/install-setuid boolean true"
  preseed "macchanger macchanger/automatically_run boolean false"
  apt_install "${network[@]}" || return
  sudo usermod -aG wireshark "$USER"
  relogin=1
}

security_step() { apt_install "${security[@]}"; }

installed=(); failed=(); skipped=(); restart=0; relogin=0

# one step: its name and what it installs, then (after a y) the function that installs it
step() {  # name, what it installs, function
  echo
  separator
  echo "${bold}$1${reset}"
  echo "$2" | fold -s -w 76 | sed 's/^/  /'
  [ $list -eq 1 ] && return
  if [ $yes -eq 1 ] || yes_no "Install?"; then
    failed_apps=""
    if "$3"; then
      installed+=("$1")
    else
      failed+=("$1${failed_apps:+: $failed_apps}")
      echo "${red}$1 failed${failed_apps:+ ($failed_apps)}; the messages above say why. Going on with the next step.${reset}"
    fi
  else
    skipped+=("$1")
  fi
}

if [ $list -eq 0 ]; then
  echo "Setting up ${PRETTY_NAME:-this computer}. sudo asks for your password once."
  sudo -v || exit 1
  apt_get update || echo "${yellow}apt update reported errors (see above); going on${reset}"
fi

step "System updates" "Everything already installed, to the newest version (apt full-upgrade)." updates_step
if lspci 2> /dev/null | grep -qi nvidia; then
  step "NVIDIA driver" "The driver Mint's Driver Manager recommends (ubuntu-drivers), nvidia-settings, and fan control in nvidia-settings (Coolbits 4, written to /etc/X11/xorg.conf). Needs a restart." nvidia_step
fi
step "Tools" "${tools[*]}" tools_step
step "System and hardware tools" "${system_tools[*]}" system_tools_step
step "Programming" "Compilers, Java, Lisp (sbcl, clisp), Node.js, Rust, PostgreSQL, the MySQL client, Python and the libraries programs compile against: ${programming[*]}" programming_step
step "Python $python_version (pyenv)" "pyenv in ~/.pyenv and the newest Python $python_version built with it, for virtual environments such as the one of pwf; the system Python stays the default. Needs the Programming step, to build Python." pyenv_step
step "R" "R from CRAN (the newest R) and what R packages need to compile: ${r_apt[*]}; then the R packages ${r_packages[*]} for all users." r_step
step "RStudio" "RStudio Desktop, newest version, from Posit." rstudio_step
step "Shiny Server and RStudio Server" "Posit's servers, newest versions, which start with the computer: the Shiny apps in /srv/shiny-server at http://localhost:3838, and RStudio in the browser at http://localhost:8787. Need the R step." servers_step
step "LaTeX" "${latex[*]}" latex_step
step "Docker" "${docker[*]}; you go in the docker group, to use it without sudo." docker_step
step "Apps" "${apps[*]}. The VirtualBox Extension Pack is free only for personal and educational use; the licence of the Microsoft fonts is accepted for you." apps_step
step "Games" "Steam from Valve, ${games[*]}" games_step
step "VS Code and Sublime Text" "VS Code from Microsoft, with your ${#vscode_extensions[@]} extensions (Claude Code, Python, R, Jupyter, LaTeX Workshop, ...), and Sublime Text from Sublime HQ; both update with the system." editors_step
step "Browsers" "Google Chrome and Microsoft Edge, each from its maker; both update with the system." browsers_step
step "Chat and calls" "Slack, Discord, Zoom and Viber, the newest .deb of each from its maker." chat_step
step "Files and VPN" "Dropbox, Insync (Google Drive and OneDrive) and Surfshark (whose installer asks for your password again)." files_step
step "TeamViewer" "From TeamViewer, which adds its repository." teamviewer_step
step "PowerShell" "From Microsoft's repository for Ubuntu $ubuntu_version." powershell_step
step "AWS CLI" "Amazon's command line tool (version 2) and its Session Manager plugin." aws_step
step "Agent DVR" "iSpy's recorder for IP cameras, at http://localhost:8090; its installer asks its own questions." agentdvr_step
step "AfterShot Pro 3" "Corel's photo editor (2017), from Corel; asks for a licence key." aftershot_step
step "Network tools" "${network[*]}. Wireshark can capture as your user." network_step
step "Security checks" "${security[*]}: a virus scanner, rootkit checks, and a check of the installed files." security_step
[ $list -eq 1 ] && exit 0

echo
separator
[ ${#installed[@]} -gt 0 ] && { echo "${green}Installed:${reset}"; printf '  %s\n' "${installed[@]}"; }
[ ${#skipped[@]} -gt 0 ] && { echo "Skipped:"; printf '  %s\n' "${skipped[@]}"; }
[ ${#failed[@]} -gt 0 ] && { echo "${red}Failed:${reset}"; printf '  %s\n' "${failed[@]}"; }
if [ $restart -eq 1 ]; then
  echo "${yellow}Restart the computer for the NVIDIA driver.${reset}"
elif [ $relogin -eq 1 ]; then
  echo "${yellow}Log out and in again, for the docker, vboxusers and wireshark groups.${reset}"
fi
echo "By hand: RealVNC Viewer from realvnc.com (it has no download link for scripts), and Mplus with your licence."
echo "Next: git_clone_all.sh downloads your repositories, r_install_packages.sh the R packages each one needs."
[ ${#failed[@]} -eq 0 ]

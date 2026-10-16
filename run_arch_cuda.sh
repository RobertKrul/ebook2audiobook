#!/usr/bin/env bash
# Startet ebook2audiobook auf Arch Linux mit erzwungenem CUDA-GPU-Backend.
# Alle Argumente werden an e2a.sh durchgereicht, z.B.:
#   ./run_arch_cuda.sh --headless --ebook ebooks/tests/test_eng.txt --language eng
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "$SCRIPT_DIR"

info()  { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
fail()  { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. Arch prüfen ──────────────────────────────────────────────────
if [[ ! -f /etc/arch-release ]]; then
	fail "Dieses Skript ist für Arch Linux gedacht (/etc/arch-release fehlt)."
fi
command -v pacman >/dev/null 2>&1 || fail "pacman nicht gefunden."
info "Arch Linux erkannt"

# ── 2. CUDA hart erzwingen ──────────────────────────────────────────
# Kein Fallback auf CPU: ohne funktionierende NVIDIA-GPU sofort abbrechen.
if ! command -v nvidia-smi >/dev/null 2>&1; then
	cat >&2 <<'EOF'
[ERROR] nvidia-smi nicht gefunden – NVIDIA-Treiber fehlt.

Auf Arch installieren (Kernel-Module + Userspace):
  sudo pacman -S nvidia nvidia-utils lib32-nvidia-utils opencl-nvidia
Pacman-Konfiguration prüfen: extra/nvidia und extra/nvidia-utils müssen
in /etc/pacman.conf aktiv sein (Blacklist nouveau beachten).
Danach rebooten und dieses Skript erneut starten.
EOF
	exit 1
fi

SMI_OUT="$(nvidia-smi -L 2>&1)" || fail "nvidia-smi schlug fehl: $SMI_OUT"
if echo "$SMI_OUT" | grep -qiE 'failed|error|no devices were found'; then
	fail "Keine NVIDIA-GPU sichtbar: $SMI_OUT"
fi
if ! echo "$SMI_OUT" | grep -qi 'gpu'; then
	fail "nvidia-smi meldet keine GPU: $SMI_OUT"
fi
info "NVIDIA-GPU gefunden: $(echo "$SMI_OUT" | head -1)"

SMI_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
info "NVIDIA-Treiber: ${SMI_VER:-unbekannt}"

# Mindest-CUDA-Version des Projekts ist 11.8 (lib/conf.py cuda_version_range).
# nvidia-smi zeigt die vom Treiber max. unterstützte CUDA-Version.
CUDA_HDR="$(nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: [0-9.]+' | head -1 | awk '{print $3}' || true)"
if [[ -n "$CUDA_HDR" ]]; then
	CUDA_MAJOR="${CUDA_HDR%%.*}"
	CUDA_MINOR="${CUDA_HDR#*.}"; CUDA_MINOR="${CUDA_MINOR%%.*}"
	if (( CUDA_MAJOR < 11 )) || { (( CUDA_MAJOR == 11 )) && (( CUDA_MINOR < 8 )); }; then
		fail "CUDA $CUDA_HDR ist zu alt (Projekt braucht >= 11.8). Treiber updaten."
	fi
	info "Treiber unterstützt CUDA $CUDA_HDR"
else
	warn "CUDA-Version aus nvidia-smi nicht lesbar – Auto-Detection in e2a.sh übernimmt."
fi

# ── 3. System-Dependencies (pacman) ─────────────────────────────────
# Entspricht HOST_PROGRAMS in e2a.sh; Pakete die schon da sind überspringen wir.
# rust/cargo: 'rust'-Paket liefert beides auf Arch.
PKGS=(
	cmake curl pkgconf calibre ffmpeg mediainfo
	nodejs espeak-ng rust sox tesseract
	tesseract-data-eng
)
# Deutsche Tesseract-Daten, wenn Locale deutsch ist
if [[ "${LANG:-}" == de_* ]]; then
	PKGS+=(tesseract-data-deu)
fi

MISSING=()
for p in "${PKGS[@]}"; do
	pacman -Q "$p" >/dev/null 2>&1 || MISSING+=("$p")
done

if (( ${#MISSING[@]} > 0 )); then
	info "Fehlende Pakete: ${MISSING[*]}"
	info "Installation via pacman (sudo nötig)…"
	sudo pacman -S --needed --noconfirm "${MISSING[@]}" \
		|| fail "pacman-Installation fehlgeschlagen: ${MISSING[*]}"
else
	info "Alle System-Pakete vorhanden"
fi

# ── 4. cuda-Device-Tag erzwingen (optional Override) ───────────────
# Ohne DEVICE_TAG läuft die Auto-Detection in e2a.sh (nvidia-smi → torch-cu-Wheel).
# Mit DEVICE_TAG=cu* wird CUDA explizit erzwungen – genau das willst du.
# Beispiel: DEVICE_TAG=cu128 ./run_arch_cuda.sh …
export DEVICE_TAG="${DEVICE_TAG:-}"

# ── 5. uv-Netzwerk: pypi.nvidia.com ist langsam/instabil ────────────
# torch-cu-Wheels ziehen nvidia-*-Pakete von pypi.nvidia.com; das ist
# häufig der Engpass (Timeout nach ~30s uv-Default). Serielle Downloads
# + langer Timeout beheben das in den meisten Fällen.
export UV_HTTP_TIMEOUT="${UV_HTTP_TIMEOUT:-600}"
export UV_CONCURRENT_DOWNLOADS="${UV_CONCURRENT_DOWNLOADS:-1}"
export UV_CONCURRENT_BUILDS="${UV_CONCURRENT_BUILDS:-1}"

# ── 6. e2a.sh starten ───────────────────────────────────────────────
info "Starte e2a.sh (Native-Modus, CUDA)…"
# e2a.sh installiert uv, Python-venv und torch+cuda-Abhängigkeiten beim ersten Lauf.
exec ./e2a.sh "$@"

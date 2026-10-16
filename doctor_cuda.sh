#!/usr/bin/env bash
# Diagnose (und optional Reparatur) der torch/CUDA-Installation von ebook2audiobook.
#
#   ./doctor_cuda.sh          # nur diagnostizieren, exit != 0 wenn torch nicht importierbar
#   ./doctor_cuda.sh --fix    # torch/torchaudio über den projekt-eigenen Installer neu installieren
#
# Prüft: nvidia-smi, .device_info.json, provisioned-Marker, installierte Pakete
# und ob `import torch` / `import torchaudio` in python_env funktioniert.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
cd "$SCRIPT_DIR"
export PATH="$HOME/.local/bin:$PATH"

DO_FIX=0
case "${1:-}" in
	--fix) DO_FIX=1 ;;
	-h|--help) echo "usage: $0 [--fix]"; exit 0 ;;
	"") ;;
	*) echo "Unbekannte Option: $1" >&2; echo "usage: $0 [--fix]" >&2; exit 2 ;;
esac

ok()   { printf '\033[32m[OK]\033[0m   %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
bad()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

PY=""
if [[ -x "python_env/bin/python3" ]]; then
	PY="$SCRIPT_DIR/python_env/bin/python3"
elif [[ -x "python_env/bin/python" ]]; then
	PY="$SCRIPT_DIR/python_env/bin/python"
fi

RC=0

hdr "NVIDIA-Treiber / GPU"
if command -v nvidia-smi >/dev/null 2>&1; then
	if SMI="$(nvidia-smi -L 2>&1)" && echo "$SMI" | grep -qi 'gpu'; then
		ok "$(echo "$SMI" | head -1)"
		CUDA_HDR="$(nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: [0-9.]+' | head -1 | awk '{print $3}' || true)"
		[[ -n "$CUDA_HDR" ]] && ok "Treiber unterstützt CUDA $CUDA_HDR"
	else
		warn "nvidia-smi meldet keine GPU: $SMI"
	fi
else
	warn "nvidia-smi nicht gefunden (kein NVIDIA-Treiber im PATH?)"
fi

hdr "Erkanntes Gerät (.device_info.json)"
if [[ -f .device_info.json ]]; then
	if command -v jq >/dev/null 2>&1; then jq . .device_info.json; else cat .device_info.json; echo; fi
	ok "device_info vorhanden"
else
	warn ".device_info.json fehlt – Launcher einmal starten, damit das Gerät erkannt wird"
fi

hdr "python_env"
if [[ -n "$PY" ]]; then
	ok "Interpreter: $PY ($("$PY" --version 2>&1))"
	if [[ -f python_env/.provisioned ]]; then
		ok "provisioned: $(cat python_env/.provisioned)"
	else
		warn "python_env/.provisioned fehlt – venv ist (noch) nicht fertig eingerichtet"
	fi
else
	bad "python_env nicht gefunden – zuerst über den Launcher provisionieren"
	RC=1
fi

hdr "Installierte Pakete (torch/coqui/transformers/nvidia)"
if command -v uv >/dev/null 2>&1 && [[ -n "$PY" ]]; then
	if ! uv pip list --python "$PY" 2>/dev/null | grep -iE 'torch|coqui|transformers|nvidia'; then
		warn "keine passenden Pakete gefunden"
	fi
else
	warn "uv nicht gefunden – Paketliste übersprungen"
fi

if [[ -n "$PY" ]]; then
	hdr "Import-Test: torch / torchaudio"
	IMPORT_LOG="$(mktemp)"
	if "$PY" -c "import torch, torchaudio" >"$IMPORT_LOG" 2>&1; then
		ok "import torch, torchaudio OK"
		"$PY" -c "import torch, torchaudio; print(f'   torch {torch.__version__} (cuda {torch.version.cuda}, available {torch.cuda.is_available()}) | torchaudio {torchaudio.__version__}')" || true
	else
		bad "import torch/torchaudio fehlgeschlagen:"
		sed 's/^/   /' "$IMPORT_LOG"
		RC=1
	fi
	rm -f "$IMPORT_LOG"
fi

if (( DO_FIX )); then
	hdr "Reparatur (--fix)"
	if [[ -z "$PY" ]]; then
		bad "python_env fehlt – bitte zuerst den Launcher ausführen, damit das venv entsteht"
		exit 1
	fi
	if [[ ! -f .device_info.json ]]; then
		bad ".device_info.json fehlt – bitte zuerst den Launcher (z. B. run_arch_cuda.sh) einmal starten"
		exit 1
	fi
	DEVICE_INFO_STR="$(cat .device_info.json)"
	printf '\033[33m[..]\033[0m install_device_packages() läuft (kann torch/torchaudio neu laden)…\n'
	if ! "$PY" - "$DEVICE_INFO_STR" <<'PYEOF'
import sys
from lib.classes.device_installer import DeviceInstaller
sys.exit(DeviceInstaller().install_device_packages(sys.argv[1]))
PYEOF
	then
		bad "install_device_packages() ist fehlgeschlagen (siehe Ausgabe oben)"
		exit 1
	fi
	if "$PY" -c "import torch, torchaudio" >/dev/null 2>&1; then
		ok "Reparatur erfolgreich – torch/torchaudio importierbar"
		RC=0
	else
		bad "torch/torchaudio weiterhin nicht importierbar"
		exit 1
	fi
fi

hdr "Ergebnis"
if (( RC == 0 )); then
	ok "CUDA/torch sieht gut aus"
else
	bad "torch/torchaudio-Problem gefunden – mit './doctor_cuda.sh --fix' reparieren"
fi
exit "$RC"

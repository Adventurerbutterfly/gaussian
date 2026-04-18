#!/usr/bin/env python3

import subprocess
from pathlib import Path

# =========================
# SETTINGS
# =========================

ROOT = Path("/cta/users/modellab/workspace/nilsu/TUBITAK/carboxylic_acids_from_PubChem").resolve()

JOBLIST = ROOT / "joblist_no_normal.txt"

FRESHOPT_DIR = ROOT / "retry_inputs" / "freshopt"
FREQ_DIR = ROOT / "retry_inputs" / "freqonly"

FAILED_OPT = ROOT / "failed_freshopt.txt"
FAILED_FREQ = ROOT / "failed_freq.txt"

# None ise orijinal %mem korunur
MEM = None

# örn: 16
NPROC = 16

# freq-only başarılı job varsa pKa scriptini çalıştır
RUN_PKA_AT_END = True

# pKa script adı
PKA_SCRIPT = "pka_from_gaussian_3.py"

# Sabit method / basis
METHOD_BASIS = "wb97xd/6-311++G(3df,3pd)"


# =========================
# HELPERS
# =========================

def parse_com_file(com_path: Path):
    """
    Orijinal .com dosyasından:
    - link0
    - title
    - charge/multiplicity + geometry + extras
    alır.
    Route kısmını kullanmıyoruz.
    """
    lines = com_path.read_text(errors="ignore").splitlines()

    link0 = []
    i = 0

    # Link0
    while i < len(lines) and lines[i].startswith("%"):
        link0.append(lines[i])
        i += 1

    # Route bölümü atla
    if i >= len(lines) or not lines[i].lstrip().startswith("#"):
        raise ValueError(f"No route section found in {com_path}")

    while i < len(lines) and lines[i].strip() != "":
        i += 1

    # route sonrası boş satırlar
    while i < len(lines) and lines[i].strip() == "":
        i += 1

    # title
    if i >= len(lines):
        raise ValueError(f"No title found in {com_path}")
    title = lines[i]
    i += 1

    # title sonrası boş satırlar
    while i < len(lines) and lines[i].strip() == "":
        i += 1

    rest = lines[i:]
    if not rest:
        raise ValueError(f"No charge/multiplicity section found in {com_path}")

    first = rest[0].split()
    if len(first) < 2 or not all(x.lstrip("+-").isdigit() for x in first[:2]):
        raise ValueError(f"Invalid charge/multiplicity line in {com_path}: {rest[0]}")

    return link0, title, rest


def extract_mem(link0_lines):
    for line in link0_lines:
        s = line.strip().lower()
        if s.startswith("%mem="):
            return line.split("=", 1)[1].strip()
    return None


def make_link0(chk_path: Path, mem_value=None):
    link0 = [
        f"%chk={chk_path}",
        f"%nprocshared={NPROC}",
    ]
    if mem_value:
        link0.append(f"%mem={mem_value}")
    return link0


def detect_phase(com_path: Path):
    """
    Dosyanın gas mı smd mi olduğuna path / filename üzerinden karar ver.
    """
    s = str(com_path).lower()

    if "/smd/" in s or "_smd_" in s or "smd_water" in s:
        return "smd"
    if "/gas/" in s or "_gas" in s:
        return "gas"

    raise ValueError(f"Could not detect phase from path: {com_path}")


def make_opt_route(phase: str):
    if phase == "smd":
        return f"#p {METHOD_BASIS} opt scrf=(smd,solvent=water)"
    elif phase == "gas":
        return f"#p {METHOD_BASIS} opt"
    else:
        raise ValueError(f"Unknown phase: {phase}")


def make_freq_route(phase: str):
    if phase == "smd":
        return f"#p {METHOD_BASIS} freq geom=allcheck guess=read scrf=(smd,solvent=water)"
    elif phase == "gas":
        return f"#p {METHOD_BASIS} freq geom=allcheck guess=read"
    else:
        raise ValueError(f"Unknown phase: {phase}")


def write_input(path: Path, link0_lines, route_line, title, rest_lines):
    text = ""
    if link0_lines:
        text += "\n".join(link0_lines) + "\n"
    text += route_line + "\n\n"
    text += title + "\n\n"
    if rest_lines:
        text += "\n".join(rest_lines).rstrip() + "\n\n"

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def write_freq_input(path: Path, link0_lines, route_line, title="Frequency job"):
    text = ""
    if link0_lines:
        text += "\n".join(link0_lines) + "\n"
    text += route_line + "\n\n"
    text += title + "\n\n"

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def normal_termination(log_path: Path):
    if not log_path.exists():
        return False
    txt = log_path.read_text(errors="ignore")
    return "Normal termination" in txt


def run_g16(inp_path: Path, log_path: Path):
    inp_path = inp_path.resolve()
    log_path = log_path.resolve()
    log_path.parent.mkdir(parents=True, exist_ok=True)

    cmd = f'g16 < "{inp_path}" > "{log_path}"'
    result = subprocess.run(cmd, shell=True, executable="/bin/bash")
    return result.returncode


# =========================
# MAIN
# =========================

def main():
    FRESHOPT_DIR.mkdir(parents=True, exist_ok=True)
    FREQ_DIR.mkdir(parents=True, exist_ok=True)

    FAILED_OPT.write_text("")
    FAILED_FREQ.write_text("")

    if not JOBLIST.exists():
        print(f"Joblist not found: {JOBLIST}")
        return

    jobs = []
    for line in JOBLIST.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        jobs.append(Path(line))

    if not jobs:
        print("Joblist empty.")
        return

    successful_freq = 0

    for com in jobs:
        com = com.resolve()

        if not com.exists():
            print(f"[SKIP] Missing com: {com}")
            with FAILED_OPT.open("a") as f:
                f.write(f"{com}\tmissing_com\n")
            continue

        print(f"\n=== Processing: {com.name} ===")

        try:
            phase = detect_phase(com)
            link0, title, rest = parse_com_file(com)
            mem_value = MEM if MEM is not None else extract_mem(link0)

            # chk dosyası freshopt altında olsun
            new_chk = (FRESHOPT_DIR / com.with_suffix(".chk").name).resolve()

            # -------- fresh optimization --------
            opt_link0 = make_link0(new_chk, mem_value)
            opt_route = make_opt_route(phase)

            opt_inp = FRESHOPT_DIR / com.name
            opt_log = FRESHOPT_DIR / com.with_suffix(".log").name

            write_input(opt_inp, opt_link0, opt_route, title, rest)

            print(f"[RUN ] fresh opt ({phase}) -> {opt_log}")
            print(f"       route: {opt_route}")
            rc1 = run_g16(opt_inp, opt_log)

            if rc1 != 0 or not normal_termination(opt_log):
                print(f"[FAIL] fresh opt failed: {com.name}")
                with FAILED_OPT.open("a") as f:
                    f.write(f"{com}\tfreshopt_failed\t{opt_log}\n")
                continue

            print(f"[ OK ] fresh opt finished: {com.name}")

            # -------- freq-only --------
            freq_link0 = make_link0(new_chk, mem_value)
            freq_route = make_freq_route(phase)

            rel = com.relative_to(ROOT)
            freq_inp = (FREQ_DIR / rel).resolve()
            freq_log = freq_inp.with_suffix(".log")

            write_freq_input(freq_inp, freq_link0, freq_route, title)

            print(f"[RUN ] freq-only ({phase}) -> {freq_log}")
            print(f"       route: {freq_route}")
            rc2 = run_g16(freq_inp, freq_log)

            if rc2 != 0 or not normal_termination(freq_log):
                print(f"[FAIL] freq-only failed: {com.name}")
                with FAILED_FREQ.open("a") as f:
                    f.write(f"{com}\tfreq_failed\t{freq_log}\n")
                continue

            print(f"[ OK ] freq-only finished: {com.name}")
            successful_freq += 1

        except Exception as e:
            print(f"[ERR ] {com.name}: {e}")
            with FAILED_OPT.open("a") as f:
                f.write(f"{com}\texception\t{e}\n")

    print("\nDone.")
    print(f"Failed fresh opt: {FAILED_OPT}")
    print(f"Failed freq     : {FAILED_FREQ}")

    if RUN_PKA_AT_END and successful_freq > 0:
        pka_path = ROOT / PKA_SCRIPT
        if pka_path.exists():
            print(f"\n[RUN ] Recalculating pKa with: {PKA_SCRIPT}")
            rc = subprocess.run(["python3", str(pka_path)], cwd=ROOT)
            if rc.returncode == 0:
                print("[ OK ] pKa recalculation finished.")
            else:
                print("[FAIL] pKa recalculation failed.")
        else:
            print(f"[SKIP] pKa script not found: {pka_path}")
    elif RUN_PKA_AT_END:
        print("\n[SKIP] No successful freq-only jobs, pKa script not run.")


if __name__ == "__main__":
    main()

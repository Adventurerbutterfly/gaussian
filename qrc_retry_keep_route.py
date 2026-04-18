#!/usr/bin/env python3
import subprocess
from pathlib import Path

ROOT = Path("/cta/users/modellab/workspace/nilsu/TUBITAK/carboxylic_acids_from_PubChem").resolve()
JOBLIST = ROOT / "joblist_imag_logs.txt"
OUTDIR = ROOT / "qrc_retry"
REPORT = ROOT / "qrc_report.tsv"

NPROC = 16
MEM = None
IMAG_THR = -0.5

RUN_PKA_AT_END = True
PKA_SCRIPT = ROOT / "pka_from_gaussian_3.py"


def sh(cmd, cwd=None):
    return subprocess.run(cmd, shell=True, executable="/bin/bash", cwd=cwd).returncode


def read_text(path: Path):
    return path.read_text(errors="ignore")


def normal_termination(log: Path):
    return log.exists() and "Normal termination" in read_text(log)


def parse_com(path: Path):
    lines = path.read_text(errors="ignore").splitlines()
    i = 0
    link0 = []

    while i < len(lines) and lines[i].startswith("%"):
        link0.append(lines[i])
        i += 1

    if i >= len(lines) or not lines[i].lstrip().startswith("#"):
        raise ValueError(f"No route section found in {path}")

    route_lines = []
    while i < len(lines) and lines[i].strip() != "":
        route_lines.append(lines[i])
        i += 1

    while i < len(lines) and lines[i].strip() == "":
        i += 1

    title = lines[i] if i < len(lines) else "QRC job"
    i += 1

    while i < len(lines) and lines[i].strip() == "":
        i += 1

    rest = lines[i:]
    return link0, route_lines, title, rest


def extract_mem(link0_lines):
    if MEM is not None:
        return MEM
    for line in link0_lines:
        s = line.strip().lower()
        if s.startswith("%mem="):
            return line.split("=", 1)[1].strip()
    return None


def normalize_route(route_lines):
    route = " ".join(line.strip() for line in route_lines)
    route = " ".join(route.split()).strip()
    return route


def split_route_top_level(route):
    tokens = []
    buf = []
    depth = 0

    for ch in route.strip():
        if ch == "(":
            depth += 1
            buf.append(ch)
        elif ch == ")":
            depth = max(depth - 1, 0)
            buf.append(ch)
        elif ch.isspace() and depth == 0:
            if buf:
                tokens.append("".join(buf))
                buf = []
        else:
            buf.append(ch)

    if buf:
        tokens.append("".join(buf))

    return tokens


def clean_route_for_opt(route):
    tokens = split_route_top_level(route)
    kept = []
    has_opt = False

    for tok in tokens:
        low = tok.lower()

        if low == "freq" or low.startswith("freq="):
            continue
        if low.startswith("geom="):
            continue
        if low.startswith("guess="):
            continue

        if low == "opt" or low.startswith("opt="):
            has_opt = True

        kept.append(tok)

    route = " ".join(kept).strip()
    if not has_opt:
        route += " opt"
    return route


def clean_route_for_freq(route):
    tokens = split_route_top_level(route)
    kept = []

    for tok in tokens:
        low = tok.lower()

        if low == "freq" or low.startswith("freq="):
            continue
        if low == "opt" or low.startswith("opt="):
            continue
        if low.startswith("geom="):
            continue
        if low.startswith("guess="):
            continue

        kept.append(tok)

    route = " ".join(kept).strip()
    route += " freq geom=allcheck guess=read"
    return route


def make_link0(chk_path: Path, mem_value=None):
    link0 = [f"%chk={chk_path}", f"%nprocshared={NPROC}"]
    if mem_value:
        link0.append(f"%mem={mem_value}")
    return link0


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


def parse_freqs(log: Path):
    vals = []
    for line in read_text(log).splitlines():
        if "Frequencies --" in line:
            for x in line.split()[2:]:
                try:
                    vals.append(float(x))
                except ValueError:
                    pass
    nimag = sum(v < IMAG_THR for v in vals)
    minfreq = min(vals) if vals else None
    return nimag, minfreq


def better(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a["nimag"] != b["nimag"]:
        return a if a["nimag"] < b["nimag"] else b
    af = a["minfreq"] if a["minfreq"] is not None else -9999.0
    bf = b["minfreq"] if b["minfreq"] is not None else -9999.0
    return a if af > bf else b


def run_trial(log_path: Path, amp: float, tag: str):
    work = OUTDIR / log_path.stem
    work.mkdir(parents=True, exist_ok=True)

    # pyQRC ile displaced com üret
    cmd = f'python3 -m pyqrc "{log_path}" --amp {amp} --name {tag}'
    rc = sh(cmd, cwd=log_path.parent)
    if rc != 0:
        return {"tag": tag, "amp": amp, "status": "pyqrc_failed", "nimag": 999, "minfreq": None}

    qrc_com = log_path.with_name(f"{log_path.stem}_{tag}.com")
    if not qrc_com.exists():
        return {"tag": tag, "amp": amp, "status": "qrc_com_missing", "nimag": 999, "minfreq": None}

    try:
        link0, route_lines, title, rest = parse_com(qrc_com)
        route = normalize_route(route_lines)
        mem_value = extract_mem(link0)

        chk = (work / f"{log_path.stem}_{tag}.chk").resolve()

        opt_route = clean_route_for_opt(route)
        freq_route = clean_route_for_freq(route)

        opt_inp = work / f"{log_path.stem}_{tag}_opt.com"
        opt_log = work / f"{log_path.stem}_{tag}_opt.log"
        freq_inp = work / f"{log_path.stem}_{tag}_freq.com"
        freq_log = work / f"{log_path.stem}_{tag}_freq.log"

        write_input(opt_inp, make_link0(chk, mem_value), opt_route, title, rest)
        if sh(f'g16 < "{opt_inp}" > "{opt_log}"') != 0 or not normal_termination(opt_log):
            return {"tag": tag, "amp": amp, "status": "opt_failed", "nimag": 999, "minfreq": None}

        write_freq_input(freq_inp, make_link0(chk, mem_value), freq_route, title)
        if sh(f'g16 < "{freq_inp}" > "{freq_log}"') != 0 or not normal_termination(freq_log):
            return {"tag": tag, "amp": amp, "status": "freq_failed", "nimag": 999, "minfreq": None}

        nimag, minfreq = parse_freqs(freq_log)
        return {
            "tag": tag,
            "amp": amp,
            "status": "ok" if nimag == 0 else "imag_left",
            "nimag": nimag,
            "minfreq": minfreq,
            "freq_log": str(freq_log),
            "opt_route": opt_route,
            "freq_route": freq_route,
        }

    except Exception as e:
        return {"tag": tag, "amp": amp, "status": f"exception:{e}", "nimag": 999, "minfreq": None}


def main():
    OUTDIR.mkdir(parents=True, exist_ok=True)

    logs = []
    for line in JOBLIST.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            logs.append(Path(line).resolve())

    rows = ["file\tchosen_tag\tamp\tstatus\tnimag\tminfreq\tfreq_log"]
    success = 0

    for log in logs:
        print(f"\n=== {log.name} ===")
        if not log.exists():
            rows.append(f"{log}\t-\t-\tmissing_log\t-\t-\t-")
            continue

        p03 = run_trial(log, 0.3, "p03")
        m03 = run_trial(log, -0.3, "m03")

        if p03["status"] == "ok":
            best = p03
        elif m03["status"] == "ok":
            best = m03
        else:
            best03 = better(p03, m03)
            amp05 = 0.5 if best03["amp"] > 0 else -0.5
            tag05 = "p05" if amp05 > 0 else "m05"
            t05 = run_trial(log, amp05, tag05)
            best = t05 if t05["status"] == "ok" else better(best03, t05)

        if best["status"] == "ok":
            success += 1

        rows.append(
            f'{log}\t{best.get("tag","-")}\t{best.get("amp","-")}\t{best.get("status","-")}\t'
            f'{best.get("nimag","-")}\t{best.get("minfreq","-")}\t{best.get("freq_log","-")}'
        )

        print(
            f"chosen={best.get('tag')}  amp={best.get('amp')}  "
            f"status={best.get('status')}  nimag={best.get('nimag')}  minfreq={best.get('minfreq')}"
        )

    REPORT.write_text("\n".join(rows) + "\n")
    print(f"\nReport written: {REPORT}")

    if RUN_PKA_AT_END and success > 0 and PKA_SCRIPT.exists():
        print(f"[RUN] {PKA_SCRIPT.name}")
        subprocess.run(["python3", str(PKA_SCRIPT)], cwd=ROOT)


if __name__ == "__main__":
    main()

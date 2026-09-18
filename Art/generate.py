#!/usr/bin/env python3
"""Generate candidate art for the assets in Art/manifest.json with the OpenArt CLI.

    Art/generate.py cast-director cast-beatmaker --model nano-banana-2 --count 2
    Art/generate.py --group machines --model nano-banana-2 --count 2 --ref Art/anchor.png
    Art/generate.py --priority 1 --model gpt-image-2 --count 1 --dry-run

Every image lands in Art/candidates/<asset>/<model>-<n>.png, and every generation is appended to
Art/ledger.jsonl with its prompt, model and credit cost, so what was spent is never a guess.

Safe to re-run: a candidate file that already exists is skipped, so only what is missing is paid
for. The whole batch is priced before anything is sent and refused if it exceeds --budget.
"""
import argparse
import concurrent.futures as futures
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ART = Path(__file__).resolve().parent
CLI = os.path.expanduser("~/.local/bin/openart")


def load_manifest():
    manifest = json.loads((ART / "manifest.json").read_text())
    style = (ART / manifest["style"]).read_text().strip()
    return manifest, style


def prompt_for(asset, manifest, style, has_reference):
    parts = [style, "Subject: " + asset["brief"]]
    if asset.get("cutout", False):
        parts.append(manifest["background"])
    if has_reference:
        parts.append("The attached reference images are the house style. Match them exactly in drawing style, "
                     "line weight, shading, palette and level of detail, but draw the new subject described "
                     "above, not the subjects of the references.")
    return "\n\n".join(parts)


def costs():
    out = subprocess.run([CLI, "model", "cost", "--plain", "--quiet"], capture_output=True, text=True, check=True)
    table = {}
    for line in out.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) >= 4 and fields[1] == "image":
            table[(fields[0], fields[2])] = int(fields[3].split()[0])
    return table


def generate(job):
    asset, model, target, prompt, refs = job
    target.parent.mkdir(parents=True, exist_ok=True)
    command = [CLI, "generate", "image", prompt, "--model", model, "-o", str(target),
               "--json", "--quiet", "--no-input", "--yes", "--timeout", "10m"]
    for ref in refs:
        command += ["--image", str(ref)]
    started = time.time()
    result = subprocess.run(command, capture_output=True, text=True)
    return job, result, time.time() - started


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("names", nargs="*", help="asset names from the manifest")
    parser.add_argument("--group", help="every generated asset in this group")
    parser.add_argument("--priority", type=int, help="every generated asset at this priority or more urgent")
    parser.add_argument("--model", required=True, action="append", help="model id; repeat to compare models")
    parser.add_argument("--count", type=int, default=2, help="candidates per asset per model")
    parser.add_argument("--ref", action="append", default=[], help="style reference image; repeatable")
    parser.add_argument("--budget", type=int, default=500, help="refuse a batch costing more credits than this")
    parser.add_argument("--dry-run", action="store_true", help="price the batch and stop")
    parser.add_argument("--parallel", type=int, default=4)
    args = parser.parse_args()

    manifest, style = load_manifest()
    assets = [a for a in manifest["assets"] if a["source"] == "generate"]
    if args.names:
        unknown = set(args.names) - {a["name"] for a in assets}
        if unknown:
            sys.exit(f"not in the manifest (or not generated): {', '.join(sorted(unknown))}")
        assets = [a for a in assets if a["name"] in args.names]
    if args.group:
        assets = [a for a in assets if a["group"] == args.group]
    if args.priority:
        assets = [a for a in assets if a["priority"] <= args.priority]
    if not assets:
        sys.exit("nothing selected")

    refs = [Path(r).resolve() for r in args.ref]
    for ref in refs:
        if not ref.exists():
            sys.exit(f"reference not found: {ref}")
    mode = "image2image" if refs else "text2image"
    table = costs()

    jobs, total = [], 0
    for asset in assets:
        for model in args.model:
            price = table.get((model, mode))
            if price is None:
                sys.exit(f"{model} has no {mode} price; see: openart model cost")
            for n in range(1, args.count + 1):
                target = ART / "candidates" / asset["name"] / f"{model}-{'ref-' if refs else ''}{n}.png"
                if target.exists():
                    continue
                jobs.append((asset, model, target, prompt_for(asset, manifest, style, bool(refs)), refs))
                total += price

    print(f"{len(jobs)} image(s), {total} credits ({mode}).")
    if not jobs:
        return
    if args.dry_run:
        for asset, model, target, _, _ in jobs:
            print(f"  {target.relative_to(ART)}")
        return
    if total > args.budget:
        sys.exit(f"refusing: {total} credits is over --budget {args.budget}")

    ledger = (ART / "ledger.jsonl").open("a")
    failures = 0
    with futures.ThreadPoolExecutor(max_workers=args.parallel) as pool:
        for job, result, seconds in pool.map(generate, jobs):
            asset, model, target, prompt, _ = job
            ok = result.returncode == 0 and target.exists()
            failures += 0 if ok else 1
            entry = {"at": time.strftime("%Y-%m-%dT%H:%M:%S"), "asset": asset["name"], "model": model,
                     "mode": mode, "credits": table[(model, mode)], "file": str(target.relative_to(ART)),
                     "ok": ok, "seconds": round(seconds, 1), "prompt": prompt,
                     "references": [str(r) for r in job[4]]}
            if not ok:
                entry["error"] = (result.stderr or result.stdout).strip()[-600:]
                # Observed 2026-09-18: an upstream NO_IMAGE failure was still charged. Assume the
                # credits are gone unless the balance says otherwise.
                entry["charged"] = "probably"
            ledger.write(json.dumps(entry) + "\n")
            ledger.flush()
            print(f"  {'ok  ' if ok else 'FAIL'} {target.relative_to(ART)}  {seconds:.0f}s"
                  + ("" if ok else f"\n       {entry['error'][:300]}"))
    print(f"done: {len(jobs) - failures} of {len(jobs)}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()

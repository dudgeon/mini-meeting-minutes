#!/usr/bin/env python3
"""Scores speaker matching against meetings whose real speakers are known.

Maintainer tool. Speaker matching (SpeakerLinker.swift) is replayed here, in Python, on the
segments and voice embeddings mmm dumps with MMM_DUMP_SEGMENTS, so different settings can be
compared in seconds instead of re-transcribing. The reference is the AMI meeting corpus's
segment annotations (CC BY 4.0, groups.inf.ed.ac.uk/ami).

    MMM_DUMP_SEGMENTS=ES2004a.jsonl ./mmm transcribe --room ES2004a.Mix-Headset.wav --stdout >/dev/null
    python3 scripts/speaker_eval.py --segments-dir ami/segments ES2004a.jsonl IS1009a.jsonl

For each meeting it reports:
  labels      speakers in the final minutes (and the most shown live, during the meeting)
  mixed       share of speech under a label that mostly belongs to someone else. Naming can't
              fix this: it's two people under one label.
  scattered   share of each person's speech outside their main label. Naming fixes this (give
              the labels the same name), at the cost of more labels to name.
"""

import argparse
import json
import re
import sys
from pathlib import Path

import numpy as np


def unit(v):
    n = np.linalg.norm(v)
    return v / n if n > 0 else v


class Linker:
    """A faithful copy of SpeakerLinker.swift: `link` per window, then `final`. Keep the defaults
    the same as its Thresholds."""

    def __init__(self, link=0.45, weak_link=0.3, short=2.0, other_local=0.6, merge=0.65, min_seconds=5.0):
        self.link_t, self.weak_t, self.short, self.other_t = link, weak_link, short, other_local
        self.merge_t, self.min_seconds = merge, min_seconds
        self.clusters = []  # duration-weighted sums of unit embeddings
        self.items = []  # (key, start, embedding, weight, live cluster)
        self.max_live = 0

    def link(self, window, segments):
        assignment, locals_in = {}, {}
        for seg in sorted(segments, key=lambda s: -s["duration"]):
            if seg["embedding"] is None:
                continue
            e = unit(np.array(seg["embedding"], dtype=np.float64))
            short = seg["duration"] < self.short
            ranked = sorted(
                ((c, float(e @ unit(self.clusters[c]))) for c in range(len(self.clusters))), key=lambda x: -x[1]
            )
            chosen = None
            for c, sim in ranked:
                required = self.weak_t if short else self.link_t
                locs = locals_in.get(c)
                if locs and seg["local"] not in locs:
                    required = max(required, self.other_t)
                if sim >= required:
                    chosen = c
                    break
            if chosen is None and short:
                chosen = next((c for c, locs in locals_in.items() if seg["local"] in locs), None)
            if chosen is None:
                self.clusters.append(np.zeros_like(e))
                chosen = len(self.clusters) - 1
            w = max(seg["duration"], 0.1)
            self.clusters[chosen] = self.clusters[chosen] + e * w
            self.items.append([(window, seg["segment"]), seg["start"], e, w, chosen])
            assignment[seg["segment"]] = chosen
            locals_in.setdefault(chosen, set()).add(seg["local"])
        self.max_live = max(self.max_live, len(self.clusters))

    def final(self):
        assignment = [it[4] for it in self.items]
        k = len(self.clusters)
        E = np.array([it[2] for it in self.items])
        W = np.array([it[3] for it in self.items])

        def centroids():
            sums = np.zeros((k, E.shape[1]))
            weights = np.zeros(k)
            for i, c in enumerate(assignment):
                sums[c] += E[i] * W[i]
                weights[c] += W[i]
            return np.array([unit(v) for v in sums]), weights

        for _ in range(10):
            changed = False
            while True:
                vec, wts = centroids()
                best = None
                for a in range(k):
                    if wts[a] <= 0:
                        continue
                    for b in range(a + 1, k):
                        if wts[b] <= 0:
                            continue
                        sim = float(vec[a] @ vec[b])
                        if sim >= self.merge_t and sim > (best[2] if best else -1):
                            best = (a, b, sim)
                if not best:
                    break
                assignment = [best[0] if c == best[1] else c for c in assignment]
                changed = True
            vec, wts = centroids()
            for i in range(len(assignment)):
                cur = assignment[i]
                cur_sim = float(E[i] @ vec[cur])
                best_c, best_s = cur, cur_sim
                for c in range(k):
                    if wts[c] > 0 and c != cur:
                        s = float(E[i] @ vec[c])
                        if s > best_s:
                            best_c, best_s = c, s
                if best_c != cur and best_s - cur_sim > 0.05:
                    assignment[i] = best_c
                    changed = True
            vec, wts = centroids()
            vec = list(vec)
            for c in sorted(range(k), key=lambda c: wts[c]):
                if not (wts[c] > 0 and wts[c] < self.min_seconds):
                    continue
                target = None
                for o in range(k):
                    if o != c and wts[o] > 0:
                        s = float(vec[c] @ vec[o])
                        if s >= self.weak_t and s > (target[1] if target else -1):
                            target = (o, s)
                if target:
                    assignment = [target[0] if a == c else a for a in assignment]
                    wts[target[0]] += wts[c]
                    wts[c] = 0
                    changed = True
            if not changed:
                break
        return {self.items[i][0]: assignment[i] for i in range(len(self.items))}


def load_dump(path):
    windows = {}
    for line in Path(path).read_text().splitlines():
        record = json.loads(line)
        windows.setdefault(record["window"], []).append(record)
    return windows


def load_reference(segments_dir, meeting):
    """Speaker -> list of (start, end) from the AMI segment annotations."""
    reference = {}
    for path in sorted(Path(segments_dir).glob(f"{meeting}.*.segments.xml")):
        speaker = path.name.split(".")[1]
        text = path.read_text(encoding="iso-8859-1")
        reference[speaker] = [
            (float(a), float(b))
            for a, b in re.findall(r'transcriber_start="([\d.]+)" transcriber_end="([\d.]+)"', text)
        ]
    return reference


def overlap(a0, a1, spans):
    return sum(max(0.0, min(a1, b1) - max(a0, b0)) for b0, b1 in spans)


def score(windows, final, reference):
    """Seconds of each reference speaker under each label."""
    table = {}
    for window, segments in windows.items():
        for seg in segments:
            label = final.get((window, seg["segment"]))
            if label is None:
                continue
            a0, a1 = seg["start"], seg["start"] + seg["duration"]
            row = table.setdefault(label, {})
            for speaker, spans in reference.items():
                row[speaker] = row.get(speaker, 0.0) + overlap(a0, a1, spans)
    labelled = sum(sum(row.values()) for row in table.values())
    mixed = sum(sum(row.values()) - max(row.values(), default=0) for row in table.values())
    scattered = 0.0
    for speaker in reference:
        times = [row.get(speaker, 0.0) for row in table.values()]
        scattered += sum(times) - max(times, default=0)
    return {
        "labels": len(table),
        "mixed": mixed / labelled if labelled else 0,
        "scattered": scattered / labelled if labelled else 0,
        "table": table,
    }


def run(windows, reference, **settings):
    linker = Linker(**settings)
    for window in sorted(windows):
        linker.link(window, windows[window])
    result = score(windows, linker.final(), reference)
    result["live"] = linker.max_live
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dumps", nargs="+", help="MMM_DUMP_SEGMENTS files, named <meeting>.jsonl")
    parser.add_argument("--segments-dir", required=True, help="AMI annotations' segments/ folder")
    parser.add_argument("--table", action="store_true", help="also print seconds per label and speaker")
    args = parser.parse_args()
    for dump in args.dumps:
        meeting = Path(dump).stem
        reference = load_reference(args.segments_dir, meeting)
        if not reference:
            sys.exit(f"No AMI segments for {meeting} in {args.segments_dir}")
        result = run(load_dump(dump), reference)
        print(
            f"{meeting}: {len(reference)} people, {result['labels']} labels ({result['live']} live), "
            f"mixed {result['mixed']:.1%}, scattered {result['scattered']:.1%}"
        )
        if args.table:
            for label, row in sorted(result["table"].items()):
                print(f"  label {label}: " + "  ".join(f"{s} {t:5.1f}s" for s, t in sorted(row.items())))


if __name__ == "__main__":
    main()

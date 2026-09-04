#!/usr/bin/env python3
"""Static contract checks for P4's one-generation frame publication surface.

This protects the fail-closed boundary: a current-frame consumer may publish
only a committed frame whose generation, front, hash and token agree with the
same capture.  It intentionally reads source only; it does not contact a
device or create a P4 request.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESIDENT = (ROOT / "objc/shared/ZiYanFrameResident.m").read_text()
HEADER = (ROOT / "objc/shared/ZiYanFrameResident.h").read_text()
HTTP = (ROOT / "tools/ziyan_framecap/ZiYanSnapshotHttp.m").read_text()
MAIN = (ROOT / "tools/ziyan_framecap/main.m").read_text()
EMBED = (ROOT / "tools/ziyan_framecap/ZiYanLuaEmbed.m").read_text()
PATHS = (ROOT / "objc/shared/ZiYanPaths.h").read_text()


def body(source: str, name: str) -> str:
    start = source.index(name)
    brace = source.index("{", start)
    depth = 0
    for end in range(brace, len(source)):
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
            if depth == 0:
                return source[start : end + 1]
    raise AssertionError(f"unclosed function {name}")


def require(ok: bool, label: str) -> None:
    if not ok:
        raise AssertionError(label)
    print(f"PASS {label}")


def main() -> int:
    committed = body(RESIDENT, "BOOL ZiYanCanonicalFrameTokenFillCommitted")
    map_read = body(RESIDENT, "BOOL ZiYanCanonicalCurrentFrameMapRead")
    token_read = body(RESIDENT, "BOOL ZiYanCanonicalFrameTokenReadCommitted")
    encode = body(HTTP, "static NSData *EncodeCanonicalPNG")
    health = body(HTTP, "void ZiYanSnapshotHttpWriteHealthAck")
    export = body(MAIN, "static void ZiYanExportFrameSeqFile")
    embed_peek = body(EMBED, "static void EmbedPeekToken")

    require("uint32_t front_hash;" in HEADER and "char publish_token[128];" in HEADER,
            "token carries front_hash_and_publish_token")
    require(all(x in committed for x in (
        "hdr->commit_seq & 1u", "frontGen != capturedGen",
        "![captured isEqualToString:front]", "hdr->front_hash != ZiYanFrameShmHashFrontBid(captured)",
        '"g%u-s%u-h%08x-t%llu"')),
            "committed_token_requires_stable_same_generation_same_front_hash")
    require("residentSeq != shmSeq" in map_read and
            "ZiYanFrameResidentMirrorFromShm()" in map_read and
            "(*outHdr)->seq != ZiYanFrameShmPeekSeq()" in map_read and
            "return NO;" in map_read,
            "stale_resident_mirrors_or_fails_closed")
    require("ZiYanCanonicalCurrentFrameMapRead" in token_read and
            "ZiYanCanonicalCurrentFrameUnmap(map, mapLen, resident);" in token_read,
            "committed_token_read_pairs_map_with_unmap")
    require("ZiYanCanonicalFrameTokenFillCommitted(" in encode and
            "if (!committed)" in encode and
            "ZiYanCanonicalCurrentFrameUnmap(map, mapLen, resident);" in encode,
            "png_refuses_uncommitted_snapshot")
    require(all(x in health for x in (
        "ZiYanCanonicalFrameTokenReadCommitted(&tok, NO)", "coherent=1",
        "publish_token=%@", "ZY_E_FRAME_INCOHERENT", "lease = coherent")),
            "health_publishes_committed_token_or_negative_coherence")
    require(all(x in export for x in (
        "ZiYanCanonicalFrameTokenReadCommitted(&tok, NO)", "coherent=0",
        "canonical_snapshot_unavailable", "publish_token=%s", "coherent=1")),
            "metrics_replaces_stale_surface_with_explicit_negative_evidence")
    require("ZiYanCanonicalFrameTokenReadCommitted(tok, ZiYanFrameKeepIsOn())" in embed_peek and
            "ZiYanFrameShmHeader fake" not in embed_peek,
            "embed_does_not_synthesize_uncommitted_header")
    require("ZiYanWriteHealthAckWithCoherence" in PATHS and
            "coherence.length ? coherence : @\"coherent=-\\n\"" in PATHS,
            "health_ack_supports_explicit_coherence_details")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, ValueError) as exc:
        print(f"FAIL {exc}", file=sys.stderr)
        raise SystemExit(1)

---
name: reverse-native
description: Reverse local native binaries (ELF/.so/exe/dll), especially JX vdk.so. Read this skill first, then use the pinned reverse-skill pack at /home/ubuntu/tools/reverse-skill for Ghidra/radare2 methodology.
---

# Reverse Native Binary

Use this skill for local, authorized reverse engineering of compiled native binaries, especially ELF shared libraries such as `vdk.so`.

Upstream reference pack is pinned at:

`/home/ubuntu/tools/reverse-skill` @ `899fedd36f5fcfa8d35a212398cd5f1166c5b9b5`

Before deep analysis, read only the relevant upstream modules instead of loading the entire security router:

1. `/home/ubuntu/tools/reverse-skill/skills/reverse-engineering/SKILL.md`
2. `/home/ubuntu/tools/reverse-skill/skills/ghidra-reverse/SKILL.md` when decompilation/headless analysis is needed.
3. `/home/ubuntu/tools/reverse-skill/skills/radare2/SKILL.md` when CLI reconnaissance is useful and `r2` is available.
4. `/home/ubuntu/tools/reverse-skill/skills/binary-diff/SKILL.md` only when comparing two versions.
5. `/home/ubuntu/tools/reverse-skill/skills/tool-index.md` for real installed paths and versions.

Do not route into pentest, exploit, EDR-bypass, attack-chain, or unrelated modules unless the user's task explicitly requires them.

## Native RE workflow

1. Preserve the original target. Work on a copy for any patch or mutation.
2. Triage first: `file`, `sha256sum`, `readelf`, `objdump`, `nm`, `strings`, loader dependencies and exported/imported symbols.
3. Map the smallest relevant behavior from strings, symbols, xrefs and callers before broad decompilation.
4. Use Ghidra headless/decompiler for structural recovery and cross-references.
5. Use `gdb`, `strace`, `ltrace` or Frida only when static evidence is insufficient and executing the target is appropriate.
6. Use radare2 as a secondary CLI view, not as a mandatory dependency.
7. For production JX binaries, never overwrite the active `.so` during analysis. If a patch is requested, create a separate patched artifact, record SHA-256 before/after, diff the exact bytes/sections changed, then deploy only after explicit verification.

## Success criteria

A reverse-engineering task is complete only when findings are tied to reproducible evidence: file/hash, architecture, relevant symbol/address, decompiler/disassembly excerpt or command output, and the verification step used to confirm the conclusion.

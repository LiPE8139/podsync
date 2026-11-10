#!/usr/bin/env python3
"""把指定二进制的 Homebrew 动态库依赖收集到目标目录，并把加载路径重写成相对路径，
使 App 内嵌的 ffmpeg / itdbwrite / libgpod 在不装 Homebrew 的机器上也能运行。"""
import os
import shutil
import subprocess
import sys

SYSTEM_PREFIXES = ("/usr/lib/", "/System/", "/Library/Apple/")


def otool_deps(path):
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout.splitlines()
    deps = []
    for line in out[1:]:
        line = line.strip()
        if not line:
            continue
        dep = line.split(" (compatibility")[0].strip()
        if dep:
            deps.append(dep)
    return deps


def rpaths(path):
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
    result, capture = [], False
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("cmd LC_RPATH"):
            capture = True
        elif capture and s.startswith("path "):
            result.append(s.split("path ")[1].split(" (offset")[0])
            capture = False
    return result


def resolve(dep, owner):
    if dep.startswith("/") and os.path.exists(dep):
        return dep
    if dep.startswith("@rpath/"):
        name = dep.split("/", 1)[1]
        for rp in rpaths(owner):
            full = os.path.join(rp.replace("@loader_path", os.path.dirname(owner)), name)
            if os.path.exists(full):
                return full
        for base in ("/opt/homebrew/lib", "/opt/homebrew/opt"):
            full = os.path.join(base, name)
            if os.path.exists(full):
                return full
    if dep.startswith("@loader_path/") or dep.startswith("@executable_path/"):
        cand = dep.replace("@loader_path", os.path.dirname(owner))
        if os.path.exists(cand):
            return cand
    return None


def bundle(entries, dest_lib, keep_system=True):
    """按“被引用的文件名”收集依赖（兼容 Homebrew 的 .61 -> .61.1.102 软链）。"""
    os.makedirs(dest_lib, exist_ok=True)
    copied = set()
    visited = set()
    queue = []
    for e in entries:
        queue.append((os.path.realpath(e), None))
    while queue:
        real, ref_name = queue.pop(0)
        key = (real, ref_name)
        if key in visited:
            continue
        visited.add(key)
        if ref_name:
            dst = os.path.join(dest_lib, ref_name)
            if ref_name not in copied and not os.path.exists(dst):
                shutil.copy2(real, dst)
                os.chmod(dst, 0o755)
                copied.add(ref_name)
        for dep in otool_deps(real):
            if any(dep.startswith(p) for p in SYSTEM_PREFIXES):
                continue
            full = resolve(dep, real)
            if not full:
                if dep.startswith("/") and keep_system:
                    continue
                print("  ! 无法解析依赖:", dep, "（来自", os.path.basename(real), "）")
                continue
            name = os.path.basename(dep)
            queue.append((os.path.realpath(full), name))
    return copied


def relocate(entries, dest_lib, dest_bin, copied):
    """把加载路径改成相对路径，并重新做 ad-hoc 签名。"""
    libs = [os.path.join(dest_lib, n) for n in sorted(os.listdir(dest_lib))]
    # 1) 库自身：id 与依赖
    for lib in libs:
        name = os.path.basename(lib)
        subprocess.run(["install_name_tool", "-id", "@loader_path/" + name, lib],
                       capture_output=True)
        for dep in otool_deps(lib):
            if any(dep.startswith(p) for p in SYSTEM_PREFIXES):
                continue
            base = os.path.basename(dep)
            if os.path.exists(os.path.join(dest_lib, base)):
                subprocess.run(["install_name_tool", "-change", dep, "@loader_path/" + base, lib],
                               capture_output=True)
    # 2) 入口程序
    for entry in entries:
        for dep in otool_deps(entry):
            if any(dep.startswith(p) for p in SYSTEM_PREFIXES):
                continue
            base = os.path.basename(dep)
            if os.path.exists(os.path.join(dest_lib, base)):
                subprocess.run(["install_name_tool", "-change", dep,
                                "@executable_path/../lib/" + base, entry],
                               capture_output=True)
    # 3) 重新 ad-hoc 签名（install_name_tool 会破坏签名）
    for p in libs + entries:
        subprocess.run(["codesign", "--force", "--sign", "-", p], capture_output=True)


def verify(entries, dest_lib):
    bad = 0
    targets = list(entries) + [os.path.join(dest_lib, f) for f in os.listdir(dest_lib)]
    for path in targets:
        for dep in otool_deps(path):
            if any(dep.startswith(s) for s in SYSTEM_PREFIXES):
                continue
            if dep.startswith("@executable_path") or dep.startswith("@loader_path"):
                continue
            print("  ✗ 仍有绝对路径:", os.path.basename(path), "->", dep)
            bad += 1
    return bad


def verify(entries, dest_lib):
    bad = 0
    for real, name in []:
        pass
    for path in entries:
        for dep in otool_deps(path):
            if any(dep.startswith(p) for p in SYSTEM_PREFIXES):
                continue
            if dep.startswith("@executable_path") or dep.startswith("@loader_path"):
                continue
            print("  ✗ 仍有绝对路径:", os.path.basename(path), "->", dep)
            bad += 1
    for fn in os.listdir(dest_lib):
        p = os.path.join(dest_lib, fn)
        for dep in otool_deps(p):
            if any(dep.startswith(s) for s in SYSTEM_PREFIXES):
                continue
            if dep.startswith("@loader_path"):
                continue
            print("  ✗ 库仍有绝对路径:", fn, "->", dep)
            bad += 1
    return bad


def main():
    if len(sys.argv) < 4:
        print("usage: bundle_deps.py <runtime-dir> <bin-dir> <bin1> [bin2...]")
        return 1
    out_dir, bin_dir = sys.argv[1], sys.argv[2]
    sources = [os.path.abspath(p) for p in sys.argv[3:]]
    os.makedirs(bin_dir, exist_ok=True)
    lib_dir = os.path.join(out_dir, "lib")
    os.makedirs(lib_dir, exist_ok=True)

    # 先把入口程序拷进 bin，再改拷贝后的副本（避免动 Homebrew 原文件）
    entries = []
    for src in sources:
        if not os.path.exists(src):
            print("缺少入口:", src)
            return 1
        dst = os.path.join(bin_dir, os.path.basename(src))
        if os.path.abspath(dst) != os.path.abspath(src):
            shutil.copy2(src, dst)
            os.chmod(dst, 0o755)
        entries.append(dst)

    copied = bundle(entries, lib_dir)
    relocate(entries, lib_dir, bin_dir, copied)
    bad = verify(entries, lib_dir)
    print("依赖库 %d 个，绝对路径残留 %d 处" % (len(copied), bad))
    return 0 if bad == 0 else 2


if __name__ == "__main__":
    sys.exit(main())

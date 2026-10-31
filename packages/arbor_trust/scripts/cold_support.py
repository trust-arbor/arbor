"""Reviewed archive/source/operator guard primitives from the Capabilities qualifier.

This helper is self-contained. The assembled qualifier pins these exact bytes
in each input manifest before preparation.
"""
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import socket
import stat
import subprocess
import tarfile
MAX_ARCHIVE_BYTES = 100_000_000

def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save_json(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def git_state(root):
    return {
        "head": git(root, "rev-parse", "HEAD").decode().strip(),
        "branch": git(root, "branch", "--show-current").decode().strip(),
        "status_sha256": sha(git(root, "status", "--porcelain=v1", "--untracked-files=all")),
        "index_sha256": sha(git(root, "ls-files", "--stage", "-z")),
        "stash_list_sha256": sha(git(root, "stash", "list", "--format=%H%x09%gd%x09%gs")),
    }


def metadata(path):
    if not path.exists() and not path.is_symlink():
        return None
    value = path.lstat()
    return [value.st_ino, value.st_mtime_ns, value.st_ctime_ns, value.st_size, value.st_mode]


def build_metadata(root):
    """Fingerprint Main's ignored build without reading or altering BEAM files."""
    if not root.exists():
        return None
    entries = [(".", metadata(root))]
    for directory, subdirectories, files in os.walk(root, followlinks=False):
        for name in sorted(subdirectories + files):
            path = Path(directory) / name
            entries.append((path.relative_to(root).as_posix(), metadata(path)))
    return {"entries": len(entries), "metadata_sha256": sha(json.dumps(sorted(entries)).encode())}


# This opt-in classifies only reviewed operational outputs, never qualification
# inputs. The legacy build_metadata(root) function and its default semantics stay
# unchanged. Existing failed receipts cannot be reinterpreted with this policy.
MAIN_BUILD_POLICIES = ("strict", "reviewed-boundary-view-v2")
REVIEWED_BOUNDARY_VIEWS = (
    "dev/lib/arbor_support/.mix/compile.boundary_view_v2",
    "dev/lib/arbor_kernel/.mix/compile.boundary_view_v2",
    "dev/lib/arbor_signals/.mix/compile.boundary_view_v2",
    "dev/lib/arbor_oauth/.mix/compile.boundary_view_v2",
    "dev/lib/arbor_capabilities_oidc/.mix/compile.boundary_view_v2",
    "dev/lib/arbor_capabilities/.mix/compile.boundary_view_v2",
    "dev/lib/arbor_capabilities_signals/.mix/compile.boundary_view_v2",
)
_BUILD_SNAPSHOT_SCHEMA = "arbor.main-build.guard-snapshot.v1"
_CACHE_TIME_FIELDS = ("mtime_ns", "ctime_ns")
_STAT_FIELDS = ("dev", "ino", "mode", "uid", "gid", "size", "nlink", "mtime_ns", "ctime_ns")


def _stat_record(value):
    kind = ("regular" if stat.S_ISREG(value.st_mode) else
            "directory" if stat.S_ISDIR(value.st_mode) else
            "symlink" if stat.S_ISLNK(value.st_mode) else "other")
    return {"kind": kind, **{key: getattr(value, "st_" + key) for key in _STAT_FIELDS}}


def _read_flags(directory=False):
    required = ("O_NOFOLLOW", "O_NONBLOCK") + (("O_DIRECTORY",) if directory else ())
    require(all(hasattr(os, name) for name in required), "No-follow snapshot support unavailable")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    for name in required:
        flags |= getattr(os, name)
    return flags


def _read_reviewed_cache(parent_fd, name, expected):
    require(expected["kind"] == "regular" and expected["nlink"] == 1,
            "Reviewed cache must be an existing single-link regular file")
    fd = os.open(name, _read_flags(), dir_fd=parent_fd)
    try:
        before = _stat_record(os.fstat(fd))
        require(before == expected and before["kind"] == "regular" and before["nlink"] == 1,
                "Reviewed cache changed before read")
        digest, length = hashlib.sha256(), 0
        while True:
            # At most the admitted size plus one byte is read. A special-file
            # substitution cannot block: open is nonblocking and fstat precedes IO.
            part = os.read(fd, min(65_536, before["size"] - length + 1))
            if not part:
                break
            length += len(part)
            require(length <= before["size"], "Reviewed cache grew during read")
            digest.update(part)
        require(length == before["size"], "Reviewed cache length changed during read")
        require(_stat_record(os.fstat(fd)) == before, "Reviewed cache changed during read")
        return {"sha256": digest.hexdigest(), "metadata": before}
    finally:
        os.close(fd)


def _walk_reviewed_build(fd, prefix, entries, caches):
    before = _stat_record(os.fstat(fd))
    require(before["kind"] == "directory", "Build ancestor is not a directory")
    entries.append((prefix or ".", before))
    for name in sorted(os.listdir(fd)):
        require(name not in (".", "..") and "/" not in name, "Unsafe build entry name")
        relative = name if not prefix else prefix + "/" + name
        value = _stat_record(os.stat(name, dir_fd=fd, follow_symlinks=False))
        if relative in REVIEWED_BOUNDARY_VIEWS:
            audit = _read_reviewed_cache(fd, name, value)
            caches[relative] = audit
            stable = {key: item for key, item in value.items() if key not in _CACHE_TIME_FIELDS}
            entries.append((relative, stable))
        elif value["kind"] == "directory":
            child_fd = os.open(name, _read_flags(directory=True), dir_fd=fd)
            try:
                require(_stat_record(os.fstat(child_fd)) == value, "Build directory changed before traversal")
                _walk_reviewed_build(child_fd, relative, entries, caches)
            finally:
                os.close(child_fd)
        else:
            if value["kind"] == "symlink":
                value = {**value, "link_target": os.readlink(name, dir_fd=fd)}
            entries.append((relative, value))
    require(_stat_record(os.fstat(fd)) == before, "Build directory changed during traversal")


def main_build_snapshot(root, policy="strict"):
    """Snapshot one fixed build tree; only an explicit closed policy admits cache outputs."""
    require(policy in MAIN_BUILD_POLICIES, "Unknown Main build policy")
    root = Path(root)
    if policy == "strict":
        return {"schema": _BUILD_SNAPSHOT_SCHEMA, "policy": policy, "root": str(root),
                "strict": build_metadata(root), "cache_audit": {}}
    require(root.is_absolute() and str(root) == os.path.normpath(str(root)), "Canonical absolute build path required")
    require(root.resolve(strict=True) == root, "Reviewed build path contains a symlinked ancestor")
    root_fd = os.open(root, _read_flags(directory=True))
    entries, caches = [], {}
    try:
        _walk_reviewed_build(root_fd, "", entries, caches)
    finally:
        os.close(root_fd)
    require(set(caches) == set(REVIEWED_BOUNDARY_VIEWS), "All seven reviewed regular caches must already exist")
    strict = {"entries": len(entries), "metadata_sha256": sha(json.dumps(sorted(entries), sort_keys=True).encode())}
    return {"schema": _BUILD_SNAPSHOT_SCHEMA, "policy": policy, "root": str(root),
            "strict": strict, "cache_audit": caches}


def _sha256_value(value):
    return isinstance(value, str) and len(value) == 64 and all(char in "0123456789abcdef" for char in value)


def _valid_cache_audit(value):
    if not isinstance(value, dict) or set(value) != {"sha256", "metadata"} or not _sha256_value(value["sha256"]):
        return False
    item = value["metadata"]
    if not isinstance(item, dict) or set(item) != {"kind", *_STAT_FIELDS}:
        return False
    if not all(type(item[key]) is int for key in _STAT_FIELDS):
        return False
    return (item["kind"] == "regular" and stat.S_ISREG(item["mode"]) and item["size"] >= 0
            and item["nlink"] == 1 and item["ino"] > 0
            and all(item[key] >= 0 for key in ("dev", "mode", "uid", "gid")))


def _valid_build_snapshot(value):
    if not isinstance(value, dict) or set(value) != {"schema", "policy", "root", "strict", "cache_audit"}:
        return False
    if value["schema"] != _BUILD_SNAPSHOT_SCHEMA or value["policy"] not in MAIN_BUILD_POLICIES or not isinstance(value["root"], str):
        return False
    fingerprint = value["strict"]
    valid_fingerprint = (isinstance(fingerprint, dict) and set(fingerprint) == {"entries", "metadata_sha256"}
                         and type(fingerprint["entries"]) is int and fingerprint["entries"] >= 1
                         and _sha256_value(fingerprint["metadata_sha256"]))
    if value["policy"] == "strict":
        return (fingerprint is None or valid_fingerprint) and value["cache_audit"] == {}
    caches = value["cache_audit"]
    return (valid_fingerprint and isinstance(caches, dict) and set(caches) == set(REVIEWED_BOUNDARY_VIEWS)
            and all(_valid_cache_audit(item) for item in caches.values()))


def main_build_cache_audit(before, after):
    """Return all seven before/after records, without admitting a change or mutating inputs."""
    require(_valid_build_snapshot(before) and _valid_build_snapshot(after), "Malformed build snapshot")
    require(before["policy"] == after["policy"], "Main build policy changed")
    if before["policy"] == "strict":
        return {}
    result = {}
    for path in REVIEWED_BOUNDARY_VIEWS:
        left, right = before["cache_audit"][path], after["cache_audit"][path]
        changed = ["metadata." + key for key in left["metadata"] if left["metadata"][key] != right["metadata"][key]]
        if left["sha256"] != right["sha256"]:
            changed.append("sha256")
        result[path] = {
            "before": {"sha256": left["sha256"], "metadata": dict(left["metadata"])},
            "after": {"sha256": right["sha256"], "metadata": dict(right["metadata"])},
            "changed_fields": sorted(changed),
        }
    return result


def compare_main_build_snapshots(before, after):
    """Admit only the selected policy's exact delta; never rebase or repair either snapshot."""
    result = {"accepted": False, "reasons": [], "cache_audit": {}}
    if not _valid_build_snapshot(before) or not _valid_build_snapshot(after):
        result["reasons"].append("Malformed Main build snapshot")
        return result
    if before["policy"] != after["policy"]:
        result["reasons"].append("Main build policy changed")
        return result
    result["cache_audit"] = main_build_cache_audit(before, after)
    if before["root"] != after["root"]:
        result["reasons"].append("Main build root changed")
    if before["strict"] != after["strict"]:
        result["reasons"].append("Strict Main build metadata changed")
    if before["policy"] == "reviewed-boundary-view-v2":
        for path, audit in result["cache_audit"].items():
            stable_left = {key: item for key, item in audit["before"]["metadata"].items() if key not in _CACHE_TIME_FIELDS}
            stable_right = {key: item for key, item in audit["after"]["metadata"].items() if key not in _CACHE_TIME_FIELDS}
            if stable_left != stable_right:
                result["reasons"].append("Reviewed cache identity changed: " + path)
    result["accepted"] = not result["reasons"]
    return result


def operator_state():
    node_id = Path.home() / ".arbor/node_id"
    node = metadata(node_id)
    if node is not None:
        require(node_id.is_file() and not node_id.is_symlink(), "Unsafe operator node_id; HOLD")
    return {
        "node_id_metadata": node,
        "node_id_sha256": sha(node_id.read_bytes()) if node is not None else None,
        # Never read the operator cookie contents.
        "cookie_metadata": metadata(Path.home() / ".erlang.cookie"),
    }


def source_files(root, allowed=None, excludes=frozenset(), sources_only=False):
    require(root.is_dir() and not root.is_symlink(), f"Missing/unsafe source root: {root}")
    paths = []
    for name in (allowed if allowed is not None else (".",)):
        path = root / name
        require(path.exists() and not path.is_symlink(), f"Missing/unsafe source input: {path}")
        paths.extend([path] if path.is_file() else sorted(path.rglob("*")))
    result = {}
    for path in paths:
        relative = path.relative_to(root)
        if any(part in excludes for part in relative.parts):
            continue
        require(not path.is_symlink(), f"Source symlink is not qualified: {path}")
        if path.is_dir():
            continue
        require(stat.S_ISREG(path.stat().st_mode), f"Non-regular source input: {path}")
        if sources_only:
            require(path.suffix not in (".beam", ".ez", ".so", ".dylib", ".dll", ".o", ".bin", ".exe", ".a"),
                    f"Compiled dependency input is not allowed: {path}")
        result[relative.as_posix()] = sha(path.read_bytes())
    require(result, f"Empty source input: {root}")
    return dict(sorted(result.items()))


def copy_files(source, destination, manifest):
    destination.mkdir(mode=0o700)
    for relative, expected in manifest.items():
        data = (source / relative).read_bytes()
        require(sha(data) == expected, f"Source changed while copying: {source / relative}")
        target = destination / relative
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with target.open("xb") as output:
            output.write(data)


def names(port):
    with socket.create_connection(("127.0.0.1", port), timeout=2) as stream:
        stream.sendall(b"\x00\x01n")
        data = b""
        while part := stream.recv(65536):
            data += part
    require(len(data) >= 4 and int.from_bytes(data[:4], "big") == port, "Wrong EPMD realm")
    return data[4:].decode("ascii")


def unpack_archive(archive, destination, expected, metadata_path):
    require(archive.is_file() and not archive.is_symlink() and archive.stat().st_size < MAX_ARCHIVE_BYTES,
            f"Missing/unsafe/oversized Hex archive: {archive}")
    with tarfile.open(archive, "r:") as outer:
        members = outer.getmembers()
        require(len(members) == 4 and
                {m.name for m in members} == {"VERSION", "CHECKSUM", "metadata.config", "contents.tar.gz"} and
                all(m.isfile() and m.size < MAX_ARCHIVE_BYTES for m in members),
                "Unexpected, duplicate or unsafe Hex outer archive entries")
        version = outer.extractfile("VERSION").read()
        checksum = outer.extractfile("CHECKSUM").read()
        package_metadata = outer.extractfile("metadata.config").read()
        compressed = outer.extractfile("contents.tar.gz").read()
    require(version == b"3", "Unexpected Hex archive format")
    require(checksum.decode("ascii").lower() == sha(version + package_metadata + compressed),
            "Hex archive checksum mismatch")
    destination.mkdir(mode=0o700)
    actual, seen, total_size = {}, set(), 0
    directories = {parent.as_posix() for relative in expected
                   for parent in PurePosixPath(relative).parents if parent.as_posix() != "."}
    with tarfile.open(fileobj=io.BytesIO(compressed), mode="r:gz") as contents:
        for member in contents:
            path = PurePosixPath(member.name)
            relative = path.as_posix()
            canonical_name = member.name.rstrip("/") if member.isdir() else member.name
            require(not path.is_absolute() and ".." not in path.parts and relative not in ("", ".") and
                    canonical_name == relative and relative not in seen,
                    f"Unsafe/duplicate package path: {member.name}")
            seen.add(relative)
            require(member.isfile() or member.isdir(), f"Unsafe package member: {member.name}")
            if member.isdir():
                require(relative in directories, f"Unexpected package directory: {relative}")
                continue
            require(relative in expected and member.size <= 10_000_000,
                    f"Unexpected/oversized package file: {relative}")
            total_size += member.size
            require(total_size < MAX_ARCHIVE_BYTES, "Oversized unpacked package")
            data = contents.extractfile(member).read()
            require(sha(data) == expected[relative], f"Published package bytes differ: {relative}")
            target = destination / relative
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with target.open("xb") as output:
                output.write(data)
            actual[relative] = sha(data)
    require(actual == expected, "Hex archive omitted published source files")
    with metadata_path.open("xb") as output:
        output.write(package_metadata)
    return {
        "archive_sha256": sha(archive.read_bytes()),
        "metadata_sha256": sha(package_metadata),
        "files": actual,
    }

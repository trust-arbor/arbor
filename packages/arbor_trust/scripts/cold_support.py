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

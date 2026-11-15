"""Transport-agnostic resume and integrity baseline for Nearby Sync.

This is deliberately not a network or cryptography implementation. It specifies
the episode manifest and retry-safe chunk bookkeeping that a platform-specific,
authenticated and encrypted transport must use.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from hashlib import sha256
from math import ceil
from pathlib import Path
from typing import Any


DEFAULT_CHUNK_SIZE = 1024 * 1024


class TransferIntegrityError(ValueError):
    """A chunk or completed payload does not match the agreed manifest."""


@dataclass(frozen=True)
class EpisodeManifest:
    """The immutable content contract agreed before transfer begins."""

    episode_id: str
    size_bytes: int
    sha256_hex: str
    chunk_size: int
    chunk_sha256: tuple[str, ...]

    def __post_init__(self) -> None:
        if not self.episode_id:
            raise ValueError("episode_id is required")
        if self.size_bytes < 0:
            raise ValueError("size_bytes cannot be negative")
        if self.chunk_size <= 0:
            raise ValueError("chunk_size must be positive")
        expected_chunk_count = ceil(self.size_bytes / self.chunk_size)
        if len(self.chunk_sha256) != expected_chunk_count:
            raise ValueError("chunk hashes do not match declared size and chunk size")
        if len(self.sha256_hex) != 64 or any(
            len(digest) != 64 for digest in self.chunk_sha256
        ):
            raise ValueError("manifest digests must be SHA-256 hex values")

    @property
    def chunk_count(self) -> int:
        return len(self.chunk_sha256)

    def to_dict(self) -> dict[str, Any]:
        return {
            "episode_id": self.episode_id,
            "size_bytes": self.size_bytes,
            "sha256_hex": self.sha256_hex,
            "chunk_size": self.chunk_size,
            "chunk_sha256": list(self.chunk_sha256),
        }

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "EpisodeManifest":
        return cls(
            episode_id=str(value["episode_id"]),
            size_bytes=int(value["size_bytes"]),
            sha256_hex=str(value["sha256_hex"]),
            chunk_size=int(value["chunk_size"]),
            chunk_sha256=tuple(str(item) for item in value["chunk_sha256"]),
        )


def build_manifest(
    source: Path, episode_id: str, chunk_size: int = DEFAULT_CHUNK_SIZE
) -> EpisodeManifest:
    """Create a content-addressed manifest without loading media into memory."""

    if chunk_size <= 0:
        raise ValueError("chunk_size must be positive")
    if not source.is_file():
        raise FileNotFoundError(source)

    complete_digest = sha256()
    chunk_digests: list[str] = []
    size_bytes = 0
    with source.open("rb") as media:
        while chunk := media.read(chunk_size):
            complete_digest.update(chunk)
            chunk_digests.append(sha256(chunk).hexdigest())
            size_bytes += len(chunk)

    return EpisodeManifest(
        episode_id=episode_id,
        size_bytes=size_bytes,
        sha256_hex=complete_digest.hexdigest(),
        chunk_size=chunk_size,
        chunk_sha256=tuple(chunk_digests),
    )


@dataclass
class TransferLedger:
    """Persistable acknowledgement state for a retry-safe receiver."""

    manifest: EpisodeManifest
    received_chunks: set[int] = field(default_factory=set)

    def record_chunk(self, index: int, payload: bytes) -> bool:
        """Verify and acknowledge a chunk; return False for a safe duplicate."""

        if index < 0 or index >= self.manifest.chunk_count:
            raise TransferIntegrityError(f"chunk index {index} is outside the manifest")
        digest = sha256(payload).hexdigest()
        if digest != self.manifest.chunk_sha256[index]:
            raise TransferIntegrityError(f"chunk {index} digest does not match manifest")
        if index in self.received_chunks:
            return False
        self.received_chunks.add(index)
        return True

    @property
    def is_complete(self) -> bool:
        return len(self.received_chunks) == self.manifest.chunk_count

    def missing_indices(self) -> tuple[int, ...]:
        return tuple(
            index
            for index in range(self.manifest.chunk_count)
            if index not in self.received_chunks
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "manifest": self.manifest.to_dict(),
            "received_chunks": sorted(self.received_chunks),
        }

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "TransferLedger":
        manifest = EpisodeManifest.from_dict(value["manifest"])
        received = {int(item) for item in value.get("received_chunks", [])}
        if any(index < 0 or index >= manifest.chunk_count for index in received):
            raise TransferIntegrityError("saved ledger contains an invalid chunk index")
        return cls(manifest=manifest, received_chunks=received)

    def verify_completed_file(self, assembled_file: Path) -> None:
        """Require all acknowledgements and a final whole-file integrity check."""

        if not self.is_complete:
            raise TransferIntegrityError("cannot verify an incomplete transfer")
        if assembled_file.stat().st_size != self.manifest.size_bytes:
            raise TransferIntegrityError("assembled file size does not match manifest")
        digest = sha256()
        with assembled_file.open("rb") as media:
            while block := media.read(DEFAULT_CHUNK_SIZE):
                digest.update(block)
        if digest.hexdigest() != self.manifest.sha256_hex:
            raise TransferIntegrityError("assembled file digest does not match manifest")

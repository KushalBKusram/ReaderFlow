import json
import tempfile
import unittest
from pathlib import Path

from transfer_ledger import (
    EpisodeManifest,
    TransferIntegrityError,
    TransferLedger,
    build_manifest,
)


class TransferLedgerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_directory.cleanup)
        self.media = Path(self.temp_directory.name) / "episode.m4a"
        self.payload = b"readerflow-nearby-sync" * 5
        self.media.write_bytes(self.payload)
        self.manifest = build_manifest(self.media, "episode-123", chunk_size=17)

    def chunks(self) -> list[bytes]:
        return [
            self.payload[offset : offset + self.manifest.chunk_size]
            for offset in range(0, len(self.payload), self.manifest.chunk_size)
        ]

    def test_manifest_is_content_addressed_and_chunked(self) -> None:
        self.assertEqual(self.manifest.size_bytes, len(self.payload))
        self.assertGreater(self.manifest.chunk_count, 1)
        self.assertEqual(len(self.manifest.sha256_hex), 64)

    def test_interrupted_transfer_resumes_from_saved_acknowledgements(self) -> None:
        chunks = self.chunks()
        ledger = TransferLedger(self.manifest)
        ledger.record_chunk(0, chunks[0])
        ledger.record_chunk(2, chunks[2])

        restored = TransferLedger.from_dict(json.loads(json.dumps(ledger.to_dict())))
        expected_missing = tuple(
            index for index in range(self.manifest.chunk_count) if index not in {0, 2}
        )
        self.assertEqual(restored.missing_indices(), expected_missing)

        for index in restored.missing_indices():
            restored.record_chunk(index, chunks[index])
        self.assertTrue(restored.is_complete)

    def test_retrying_an_acknowledged_chunk_is_safe(self) -> None:
        chunk = self.chunks()[0]
        ledger = TransferLedger(self.manifest)
        self.assertTrue(ledger.record_chunk(0, chunk))
        self.assertFalse(ledger.record_chunk(0, chunk))
        self.assertEqual(ledger.missing_indices(), tuple(range(1, self.manifest.chunk_count)))

    def test_tampered_chunk_is_rejected_without_advancing_resume_state(self) -> None:
        ledger = TransferLedger(self.manifest)
        with self.assertRaises(TransferIntegrityError):
            ledger.record_chunk(0, b"tampered")
        self.assertEqual(ledger.missing_indices()[0], 0)

    def test_manifest_rejects_inconsistent_chunk_count(self) -> None:
        with self.assertRaises(ValueError):
            EpisodeManifest("episode-123", 18, "0" * 64, 17, ("0" * 64,))

    def test_finalization_requires_complete_matching_file(self) -> None:
        chunks = self.chunks()
        ledger = TransferLedger(self.manifest)
        with self.assertRaises(TransferIntegrityError):
            ledger.verify_completed_file(self.media)
        for index, chunk in enumerate(chunks):
            ledger.record_chunk(index, chunk)
        ledger.verify_completed_file(self.media)
        self.media.write_bytes(b"different")
        with self.assertRaises(TransferIntegrityError):
            ledger.verify_completed_file(self.media)

from fastapi.testclient import TestClient
import fitz
import pytest
import shutil

from main import app


client = TestClient(app)
HAS_TESSERACT = shutil.which("tesseract") is not None


def make_text_png(text: str) -> bytes:
    doc = fitz.open()
    page = doc.new_page(width=640, height=280)
    page.insert_text((72, 150), text, fontsize=32)
    pix = page.get_pixmap(matrix=fitz.Matrix(2, 2), alpha=False)
    data = pix.tobytes("png")
    doc.close()
    return data


def test_health_route_should_return_ok_status() -> None:
    response = client.get("/health")

    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ok"
    assert payload["service"] == "ocr-service"


def test_ocr_pdf_route_should_reject_invalid_path() -> None:
    request_body = {
        "source_path": "/tmp/non-existent.pdf",
        "language": "zh",
    }

    response = client.post("/ocr/pdf", json=request_body)
    assert response.status_code == 400
    assert "Failed to open PDF" in response.json()["detail"]


def test_ocr_image_route_should_reject_invalid_path() -> None:
    response = client.post("/ocr/image", json={"source_path": "/tmp/demo.png", "language": "auto"})

    assert response.status_code == 400
    assert "Failed to open image" in response.json()["detail"]


def test_ocr_route_should_validate_required_source_path() -> None:
    response = client.post("/ocr/pdf", json={"language": "zh"})
    assert response.status_code == 422


def test_ocr_pdf_upload_should_extract_real_pdf_text() -> None:
    doc = fitz.open()
    page = doc.new_page(width=400, height=240)
    sample_text = "BookLLM OCR selectable text test."
    page.insert_text((72, 96), sample_text, fontsize=16)
    pdf_bytes = doc.tobytes()
    doc.close()

    response = client.post(
        "/ocr/pdf/upload",
        data={"language": "auto"},
        files={"file": ("smoke.pdf", pdf_bytes, "application/pdf")},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ok"
    assert payload["pageCount"] == 1
    assert payload["scannedPages"] == 0
    assert payload["pages"][0]["pageNumber"] == 1
    assert sample_text in payload["pages"][0]["text"]


@pytest.mark.skipif(not HAS_TESSERACT, reason="tesseract binary is not installed")
def test_ocr_image_upload_should_extract_text_from_real_image() -> None:
    image_bytes = make_text_png("BookLLM image OCR test")

    response = client.post(
        "/ocr/image/upload",
        data={"language": "en"},
        files={"file": ("scan.png", image_bytes, "image/png")},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ok"
    assert payload["pageCount"] == 1
    assert payload["scannedPages"] == 1
    assert "BookLLM" in payload["pages"][0]["text"]
    assert "OCR" in payload["pages"][0]["text"]


@pytest.mark.skipif(not HAS_TESSERACT, reason="tesseract binary is not installed")
def test_ocr_pdf_upload_should_ocr_full_page_scanned_image() -> None:
    image_bytes = make_text_png("BookLLM scanned PDF OCR")
    doc = fitz.open()
    page = doc.new_page(width=640, height=280)
    page.insert_image(page.rect, stream=image_bytes)
    pdf_bytes = doc.tobytes()
    doc.close()

    response = client.post(
        "/ocr/pdf/upload",
        data={"language": "en"},
        files={"file": ("scanned.pdf", pdf_bytes, "application/pdf")},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ok"
    assert payload["pageCount"] == 1
    assert payload["scannedPages"] == 1
    assert payload["pages"][0]["isScanned"] is True
    assert "BookLLM" in payload["pages"][0]["text"]
    assert "OCR" in payload["pages"][0]["text"]
    assert "[[OB_IMAGE:" not in payload["pages"][0]["text"]

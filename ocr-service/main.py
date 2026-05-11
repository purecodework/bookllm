"""
BookLLM OCR Service — PDF text extraction, image preservation, and scanned-page OCR.

PDF pages use selectable text when available. Pages with little/no text and a
large page-covering image are treated as scanned pages and passed through
Tesseract OCR. Ordinary illustrations are preserved as image markers and are not
mixed into the document text.
"""

import base64
import os
import shutil
import subprocess
import tempfile
from typing import Literal

import fitz  # PyMuPDF
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from pydantic import BaseModel, Field

app = FastAPI(
    title="BookLLM OCR Service",
    description="PDF text-layer extraction, image preservation, and scanned-page OCR.",
    version="0.4.0",
)

# Pages with fewer text-layer characters than this are candidates for scanned OCR.
SCAN_PAGE_TEXT_THRESHOLD = 30
# A page-covering image is treated as scanned content when it covers most of the page.
SCAN_IMAGE_AREA_RATIO = 0.70
# Avoid accidentally OCRing tiny icons/logos.
MIN_OCR_IMAGE_BYTES = 1024


# ── Data models ───────────────────────────────────────────────────────────────

class HealthResponse(BaseModel):
    status: Literal["ok"]
    service: str


class OcrRequest(BaseModel):
    source_path: str = Field(..., min_length=1)
    language: str = Field(default="auto")
    ocrMode: Literal["auto", "force"] = "auto"


class PageImage(BaseModel):
    relativePath: str
    ext: str
    dataBase64: str
    alt: str = "Illustration"
    coverageRatio: float = 0


class PageResult(BaseModel):
    pageNumber: int
    text: str
    isScanned: bool
    images: list[PageImage] = Field(default_factory=list)


class OcrResponse(BaseModel):
    status: Literal["ok"]
    pageCount: int
    scannedPages: int
    pages: list[PageResult]


# ── Core extraction ───────────────────────────────────────────────────────────

def _image_marker(relative_path: str, alt: str) -> str:
    safe_alt = alt.replace("|", " ").replace("]", " ").strip()
    return f"[[OB_IMAGE:{relative_path}|{safe_alt}]]"


def _normalise_ocr_text(text: str) -> str:
    lines = [line.strip() for line in text.replace("\r", "\n").split("\n")]
    blocks: list[str] = []
    current: list[str] = []
    for line in lines:
        if not line:
            if current:
                blocks.append(" ".join(current).strip())
                current = []
            continue
        current.append(line)
    if current:
        blocks.append(" ".join(current).strip())
    return "\n\n".join(block for block in blocks if block)


def _tesseract_language(language: str) -> str:
    mapping = {
        "auto": "eng",
        "en": "eng",
        "zh": "chi_sim+eng",
        "zh-cn": "chi_sim+eng",
        "ja": "jpn+eng",
        "ko": "kor+eng",
        "fr": "fra+eng",
        "de": "deu+eng",
        "es": "spa+eng",
        "ru": "rus+eng",
    }
    return mapping.get(language.lower(), "eng")


def _run_tesseract(image_bytes: bytes, language: str) -> str:
    if shutil.which("tesseract") is None:
        raise HTTPException(status_code=503, detail="Tesseract OCR binary is not installed")

    with tempfile.NamedTemporaryFile(suffix=".png") as image_file:
        image_file.write(image_bytes)
        image_file.flush()
        try:
            completed = subprocess.run(
                ["tesseract", image_file.name, "stdout", "-l", _tesseract_language(language)],
                check=True,
                capture_output=True,
                text=True,
                timeout=60,
            )
        except subprocess.TimeoutExpired as exc:
            raise HTTPException(status_code=504, detail="Image OCR timed out") from exc
        except subprocess.CalledProcessError as exc:
            detail = (exc.stderr or exc.stdout or "Image OCR failed").strip()
            # Missing language packs should be visible but not cryptic.
            raise HTTPException(status_code=502, detail=detail) from exc

    return _normalise_ocr_text(completed.stdout)


def _ocr_page_pixmap(page: fitz.Page, language: str) -> str:
    # Render at 2x scale to give Tesseract enough detail without huge memory use.
    pix = page.get_pixmap(matrix=fitz.Matrix(2, 2), alpha=False)
    return _run_tesseract(pix.tobytes("png"), language)


def _image_coverage(block: dict, page: fitz.Page) -> float:
    bbox = block.get("bbox")
    if not isinstance(bbox, (list, tuple)) or len(bbox) != 4:
        return 0
    x0, y0, x1, y1 = [float(v) for v in bbox]
    image_area = max(x1 - x0, 0) * max(y1 - y0, 0)
    page_area = max(page.rect.width * page.rect.height, 1)
    return image_area / page_area


def _extract_page_content(
    page: fitz.Page,
    page_number: int,
    language: str,
    force_ocr: bool = False,
) -> tuple[str, list[PageImage], int, bool]:
    """
    Extract text and images from a single PDF page.

    Text-layer blocks are preferred. If text is sparse and a large image covers
    most of the page, OCR is run on a rendered page image and the page-covering
    scan is not inserted as an image marker into the document body.
    """
    raw_dict = page.get_text("dict", sort=True)

    text_blocks: list[str] = []
    image_blocks: list[tuple[PageImage, str]] = []
    text_char_count = 0
    image_index = 0
    largest_coverage = 0.0
    largest_image_bytes = 0

    for block in raw_dict.get("blocks", []):
        block_type = int(block.get("type", -1))

        if block_type == 0:  # text block
            lines = []
            for line in block.get("lines", []):
                spans = line.get("spans", [])
                line_text = "".join(str(span.get("text", "")) for span in spans).strip()
                if line_text:
                    lines.append(line_text)
            merged = " ".join(lines).strip()
            if merged:
                text_char_count += len(merged)
                text_blocks.append(merged)
            continue

        if block_type == 1:  # image block
            image_bytes = block.get("image")
            if not isinstance(image_bytes, (bytes, bytearray)) or len(image_bytes) == 0:
                continue

            image_index += 1
            ext = str(block.get("ext") or "png").lower()
            coverage = _image_coverage(block, page)
            largest_coverage = max(largest_coverage, coverage)
            largest_image_bytes = max(largest_image_bytes, len(image_bytes))
            relative_path = f"images/pdf-p{page_number}-img{image_index}.{ext}"
            image = PageImage(
                relativePath=relative_path,
                ext=ext,
                dataBase64=base64.b64encode(bytes(image_bytes)).decode("ascii"),
                alt=f"Page {page_number} image {image_index}",
                coverageRatio=round(coverage, 4),
            )
            image_blocks.append((image, _image_marker(relative_path, image.alt)))

    should_ocr_scanned_page = force_ocr or (
        text_char_count < SCAN_PAGE_TEXT_THRESHOLD
        and largest_coverage >= SCAN_IMAGE_AREA_RATIO
        and largest_image_bytes >= MIN_OCR_IMAGE_BYTES
    )

    if should_ocr_scanned_page:
        ocr_text = _ocr_page_pixmap(page, language)
        if ocr_text:
            return ocr_text, [image for image, _marker in image_blocks], text_char_count, True

    blocks = text_blocks + [marker for _image, marker in image_blocks]
    return "\n\n".join(blocks), [image for image, _marker in image_blocks], text_char_count, False


def _process_doc(doc: fitz.Document, language: str = "auto", ocr_mode: str = "auto") -> OcrResponse:
    pages: list[PageResult] = []
    scanned_count = 0
    force_ocr = ocr_mode == "force"

    for i in range(len(doc)):
        text, images, text_chars, is_scanned = _extract_page_content(
            doc[i],
            i + 1,
            language,
            force_ocr=force_ocr,
        )
        if not is_scanned and text_chars < SCAN_PAGE_TEXT_THRESHOLD and len(images) == 0:
            is_scanned = True
            text = ""
        if is_scanned:
            scanned_count += 1
        pages.append(PageResult(pageNumber=i + 1, text=text, isScanned=is_scanned, images=images))

    return OcrResponse(
        status="ok",
        pageCount=len(pages),
        scannedPages=scanned_count,
        pages=pages,
    )


def _process_image_bytes(content: bytes, language: str = "auto") -> OcrResponse:
    text = _run_tesseract(content, language)
    return OcrResponse(
        status="ok",
        pageCount=1,
        scannedPages=1,
        pages=[PageResult(pageNumber=1, text=text, isScanned=True, images=[])],
    )


# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(status="ok", service="ocr-service")


@app.post("/ocr/pdf/upload", response_model=OcrResponse)
async def ocr_pdf_upload(
    file: UploadFile = File(...),
    language: str = Form(default="auto"),
    ocrMode: Literal["auto", "force"] = Form(default="auto"),
) -> OcrResponse:
    """Multipart PDF upload endpoint called by the backend container."""
    content = await file.read()
    try:
        doc = fitz.open(stream=content, filetype="pdf")
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to parse PDF: {e}") from e
    result = _process_doc(doc, language, ocrMode)
    doc.close()
    return result


@app.post("/ocr/image/upload", response_model=OcrResponse)
async def ocr_image_upload(
    file: UploadFile = File(...),
    language: str = Form(default="auto"),
) -> OcrResponse:
    """Multipart image OCR endpoint called by the backend container."""
    content = await file.read()
    if len(content) < MIN_OCR_IMAGE_BYTES:
        raise HTTPException(status_code=400, detail="Image file is too small for OCR")
    return _process_image_bytes(content, language)


@app.post("/ocr/pdf", response_model=OcrResponse)
def ocr_pdf(payload: OcrRequest) -> OcrResponse:
    """File-path endpoint for in-container PDF calls."""
    try:
        doc = fitz.open(payload.source_path)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to open PDF: {e}") from e
    result = _process_doc(doc, payload.language, payload.ocrMode)
    doc.close()
    return result


@app.post("/ocr/image", response_model=OcrResponse)
def ocr_image(payload: OcrRequest) -> OcrResponse:
    """File-path image OCR endpoint."""
    if not os.path.exists(payload.source_path):
        raise HTTPException(status_code=400, detail=f"Failed to open image: {payload.source_path}")
    with open(payload.source_path, "rb") as f:
        return _process_image_bytes(f.read(), payload.language)

"""
Шрифт для PDF с кириллицей: встроенный Helvetica в ReportLab её не рисует (квадраты на Mac/iOS).
Ищем TTF (DejaVu в проекте, Arial Unicode на macOS, DejaVu в Linux, Arial в Windows).
"""
from pathlib import Path

from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

FONT_REGISTERED_NAME = 'AppCyrillicSans'
_registered = False


def register_cyrillic_font():
    """Один раз регистрирует шрифт; возвращает имя для Paragraph или None."""
    global _registered
    if _registered:
        return FONT_REGISTERED_NAME

    candidates = [
        Path(__file__).resolve().parent / 'fonts' / 'DejaVuSans.ttf',
        Path('/Library/Fonts/Arial Unicode.ttf'),
        Path('/System/Library/Fonts/Supplemental/Arial Unicode.ttf'),
        Path('/System/Library/Fonts/Supplemental/Arial.ttf'),
        Path('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'),
        Path('C:/Windows/Fonts/arial.ttf'),
    ]
    for path in candidates:
        if not path.is_file():
            continue
        try:
            pdfmetrics.registerFont(TTFont(FONT_REGISTERED_NAME, str(path)))
            _registered = True
            return FONT_REGISTERED_NAME
        except Exception:
            continue
    return None

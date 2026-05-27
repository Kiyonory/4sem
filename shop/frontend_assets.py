import json
from pathlib import Path

from django.conf import settings


def vite_production_assets():
    """Пути к собранным файлам Vite (manifest.json после npm run build)."""
    frontend_dir = Path(settings.BASE_DIR) / 'static' / 'frontend'
    manifest_path = frontend_dir / '.vite' / 'manifest.json'
    if not manifest_path.is_file():
        manifest_path = frontend_dir / 'manifest.json'
    if not manifest_path.is_file():
        return {'vite_built': False, 'vite_css': [], 'vite_js': []}

    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    entry = manifest.get('index.html')
    if not entry:
        for key, value in manifest.items():
            if key.endswith('.html') and isinstance(value, dict) and 'file' in value:
                entry = value
                break

    if not entry:
        return {'vite_built': False, 'vite_css': [], 'vite_js': []}

    css = [f'frontend/{name}' for name in entry.get('css', [])]
    js_files = []

    for imp in entry.get('imports', []):
        chunk = manifest.get(imp, {})
        if chunk.get('file'):
            js_files.append(f'frontend/{chunk["file"]}')

    if entry.get('file'):
        js_files.append(f'frontend/{entry["file"]}')

    return {'vite_built': True, 'vite_css': css, 'vite_js': js_files}

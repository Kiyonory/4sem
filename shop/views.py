import os

from django.conf import settings
from django.http import JsonResponse
from django.shortcuts import render

from shop.frontend_assets import vite_production_assets


def api_health(request):
    return JsonResponse({'status': 'ok', 'backend': 'django'})


def vue_app(request):
    use_vite_dev = settings.DEBUG and os.environ.get('FRONTEND_USE_VITE_DEV', '1') == '1'
    context = {
        'vite_dev': use_vite_dev,
        'vite_dev_server': getattr(settings, 'FRONTEND_VITE_DEV_SERVER', 'http://localhost:5173'),
    }
    if not use_vite_dev:
        context.update(vite_production_assets())
    else:
        context['vite_built'] = True
    return render(request, 'frontend/app.html', context)

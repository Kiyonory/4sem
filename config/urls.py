from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.shortcuts import redirect
from django.urls import path


def _redirect_root_to_admin(request):
    return redirect('admin:index')


urlpatterns = [
    path('admin/', admin.site.urls),
    path('', _redirect_root_to_admin),
]

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)

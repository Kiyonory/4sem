# Лаба 6: контекст для страницы демонстрации ORM в админке (см. Lab6ScratchAdmin).
from django.core.cache import cache
from django.db import connection
from django.db.models import F
from django.db.models.functions import Lower
from django.http import Http404

from .models import Lab6Scratch, Product


def get_lab6_demonstration_context(request, base_qs=None):
    if request.GET.get('notfound'):
        raise Http404('Демонстрация Http404 для Лабы 6.')

    base_qs_was_provided = base_qs is not None
    base_qs = base_qs if base_qs is not None else Product.objects.all()
    if base_qs_was_provided:
        base_pks = list(base_qs.values_list('pk', flat=True))
        base_qs = Product.objects.filter(pk__in=base_pks)

    sample_letter_base = 'a'
    if base_qs_was_provided:
        first_name = base_qs.values_list('name', flat=True).first()
        if first_name:
            first_ascii_letter = next((ch for ch in first_name if ch.isascii() and ch.isalpha()), None)
            if first_ascii_letter:
                sample_letter_base = first_ascii_letter
            else:
                # fallback: первый непробельный символ
                first_char = next((ch for ch in first_name if not ch.isspace()), None)
                if first_char:
                    sample_letter_base = first_char

    sample_letter_base = (sample_letter_base or '').strip()
    sample_letter = sample_letter_base.lower() if sample_letter_base else 'a'

    case_demo_qs = base_qs
    case_demo_note = None
    if not (sample_letter_base and sample_letter_base.isascii() and sample_letter_base.isalpha()):
        case_demo_qs = Product.objects.all()
        sample_letter = 'v'
        case_demo_note = (
            "Для железной разницы case-операторов на SQLite берём латинскую 'v' "
            "(в выбранных названиях кириллица)."
        )

    # case-insensitive “железно”: Lower(name) ... contains
    icontains_qs = (
        case_demo_qs.annotate(name_l=Lower('name'))
        .filter(name_l__contains=sample_letter)[:8]
    )

    # case-sensitive “железно” на SQLite: GLOB чувствителен к регистру
    if connection.vendor == 'sqlite':
        table = Product._meta.db_table
        # Для одиночной буквы этого достаточно (GLOB спецсимволов здесь нет).
        pattern = f"*{sample_letter}*"
        contains_qs = case_demo_qs.extra(where=[f"{table}.name GLOB %s"], params=[pattern])[:8]
    else:
        # На других БД оставляем семантику Django `contains`.
        contains_qs = case_demo_qs.filter(name__contains=sample_letter)[:8]

    values_sample = list(base_qs.values('id', 'name', 'base_price')[:5])
    values_list_tuples = list(base_qs.values_list('id', 'name')[:5])
    values_list_flat = list(base_qs.values_list('name', flat=True)[:5])

    products_count = base_qs.count()
    products_exist = base_qs.exists()
    brands_exist = base_qs.filter(brand__name__icontains='ZZZ_NONEXISTENT').exists()

    cache_key = 'lab6_product_count'
    cached_val = cache.get(cache_key)
    cache_hit = cached_val is not None
    if not cache_hit:
        cached_val = Product.objects.count()
        cache.set(cache_key, cached_val, 300)

    scratch = Lab6Scratch.objects.create(
        label='lab6_demo_row',
        link='https://docs.djangoproject.com/',
        counter=0,
    )
    Lab6Scratch.objects.filter(pk=scratch.pk).update(counter=F('counter') + 1)
    scratch.refresh_from_db()
    counter_after_f = scratch.counter
    deleted_count, deleted_by_model = Lab6Scratch.objects.filter(pk=scratch.pk).delete()

    return {
        'sample_letter': sample_letter,
        'icontains_qs': icontains_qs,
        'contains_qs': contains_qs,
        'values_sample': values_sample,
        'values_list_tuples': values_list_tuples,
        'values_list_flat': values_list_flat,
        'products_count': products_count,
        'products_exist': products_exist,
        'brands_exist': brands_exist,
        'cache_hit': cache_hit,
        'cached_count': cached_val,
        'counter_after_f': counter_after_f,
        'deleted_count': deleted_count,
        'deleted_by_model': deleted_by_model,
        'urlfield_example': 'Product.image_url и Lab6Scratch.link — поля модели URLField()',
        'case_demo_note': case_demo_note,
    }

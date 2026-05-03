# Лаба 6 — что сделано в проекте и ответы на вопросы

Демонстрация **только в админке Django**. Из-за требований “все показывать через админку” публичной страницы `/lab6/` нет.

## Что именно демонстрирует Лаба 6

1. `models.URLField()` — есть два поля URL:
   - `Product.image_url` (в карточке товара в админке)
   - `Lab6Scratch.link` (поле модели “Лаба 6 (scratch)”, используется как пример URLField)

2. Методы QuerySet/фильтры:
   - `__icontains` / `__contains` по `Product.name`
   - `values()` / `values_list()`
   - `count()` / `exists()`

3. “Обновление без чтения в Python” и чистка:
   - `update()` на `Lab6Scratch` с `F('counter') + 1`
   - `delete()` созданной строки

4. Кеш:
   - `cache.get()` / `cache.set()` (LocMemCache) на ключ `lab6_product_count`

5. `Http404`:
   - если в URL передать `?notfound=1`, демонстрация специально выбрасывает `Http404`.

## Как показывать преподавателю (пошагово)

1. Убедись, что есть товары `Product` (иначе выборки будут пустыми).
   - Проще всего: `python manage.py fill_fake_data` (в админку товары потом появятся сами).

2. Самый удобный способ: сделать действие в админке (без перехода на отдельную страницу):
   - Админка -> раздел **«Товары»** -> выдели любые товары -> внизу в блоке **Actions** выбери **«Демо Лабы 6 (ORM) для товаров»** -> подтвердить.
   - После выполнения вверху админки появится сообщение с ключевыми результатами (cache_hit, counter_after_f, deleted_count и т.д.).

3. Что смотреть в сообщении (вверху админки):
   - буква для `__icontains/__contains` берётся из первой буквы имени **первого выбранного** товара
   - сверху будет строка из `urlfield_example` (пример того, что такое URLField)
   - блоки с `__icontains` и `__contains`: должны показаться названия продуктов
   - в проекте Лаба 6 демонстрирует разницу “железно” за счёт Lower(name) для `icontains` и GLOB для `contains` (SQLite)
   - `values()` / `values_list()` : выводятся списки/кортежи (обычно в `<pre>` виде)
   - `count()` / `exists()` : должны быть числа/булевые значения (есть ли товары и есть ли “несуществующий бренд”)
   - блок кеша: поле `cache_hit` — `False` при первом открытии и `True` при повторном открытии в течение TTL
   - блок `update()` / `delete()` : `counter_after_f` (ожидается увеличенное значение) и `deleted_count` (обычно `1`)

4. Для проверки `Http404`:
   - открой `/admin/shop/lab6scratch/reference/?notfound=1`
   - должна появиться страница “404 Not Found”.

---

## Вопрос: кеш-фреймворк

**Ответ:** В `config/settings.py` задан `CACHES` с бэкендом **`django.core.cache.backends.locmem.LocMemCache`** (кеш в памяти процесса, удобно для разработки). Во `get_lab6_demonstration_context` используется API **`django.core.cache.cache`**: `cache.get('lab6_product_count')`, при отсутствии значения — подсчёт `Product.objects.count()` и **`cache.set(..., timeout=300)`**. Повторная загрузка страницы в течение TTL берёт число из кеша без запроса к БД.

В продакшене чаще используют **Redis** или **Memcached** (`django.core.cache.backends.redis.RedisCache` и т.д.) с общим кешем для нескольких воркеров.

---

## Вопрос: F expressions

**Ответ:** **`F`** — выражение, ссылающееся на **значение поля в БД** в момент выполнения запроса. Нужно, чтобы не читать объект в Python и не делать гонки при обновлении: например, `Model.objects.filter(...).update(views=F('views') + 1)` или `stock_quantity=F('stock_quantity') - delta`.

В проекте: **`Lab6Scratch.objects.filter(pk=...).update(counter=F('counter') + 1)`** в `get_lab6_demonstration_context`; в **`OrderItem.save` / `delete`** — обновление остатка варианта через `F('stock_quantity')`.

---

## Вопрос: The Http404 exception

**Ответ:** Исключение **`django.http.Http404`** сигнализирует фреймворку, что ресурс не найден. Обработчик (в т.ч. **`handler404`**) отдаёт ответ со **статусом 404**. Удобно вызывать через **`get_object_or_404(Model, pk=...)`** — при отсутствии записи выбрасывается `Http404`.

В проекте для демонстрации: в **`get_lab6_demonstration_context`** при `?notfound=1` выполняется **`raise Http404('...')`**. Для защиты достаточно показать ссылку **`/admin/shop/lab6scratch/reference/?notfound=1`** или привести пример с `get_object_or_404` в коде.

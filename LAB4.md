# Лаба 4 (Django 4, часть 2) — что сделано в проекте

Демонстрация — **только в админке Django** (отдельный HTML-фронтенд не используется).

## 1. Создание, редактирование, удаление

- **Теги (`Tag`)** — полный CRUD в разделе **«Теги»** админки (`TagAdmin`).
- **Товары (`Product`)** — создание и редактирование в **«Товары»**; связи **товар ↔ тег** настраиваются через инлайн **«Теги товаров»** (`ProductTagInline`) и/или через M2M с учётом промежуточной модели.
- **Похожие товары** — инлайн **«Похожие товары»** (`ProductSimilarInline`) на странице товара.

## 2. `requirements.txt`

В корне проекта файл **`requirements.txt`** со списком пакетов (Django, Faker и т.д.).

### Вопрос: `pip install -r requirements.txt`

**Ответ:** Команда устанавливает все зависимости из файла `requirements.txt` в текущее виртуальное окружение. Флаг `-r` означает «прочитать список пакетов из файла»; pip по очереди ставит указанные версии. Так все участники проекта и сервер получают одинаковый набор библиотек. Обычно сначала создают venv, активируют его, затем выполняют `pip install -r requirements.txt`.

## 3. `ManyToManyField` с `through`

- **Теги товара:** `Product.tags` → промежуточная модель **`ProductTag`** с полями `product`, `tag`, **`sort_order`** (дополнительное поле в связи).

```python
tags = models.ManyToManyField(Tag, through='ProductTag', ...)
```

- **Похожие товары:** `Product.similar_products` — связь **на себя** через **`ProductSimilar`** с двумя внешними ключами на `Product` (`from_product`, `to_product`). Здесь указаны **`through_fields=('from_product', 'to_product')`** — как в [документации Django](https://docs.djangoproject.com/en/5.1/ref/models/fields/#django.db.models.ManyToManyField.through_fields), чтобы Django понял, какие два поля участвуют в M2M.

Код: `shop/models.py` — классы `Tag`, `ProductTag`, `ProductSimilar`, поля у `Product`.

## 4. `select_related()` и `prefetch_related()`

**Где:** `ProductAdmin.get_queryset()` в `shop/admin.py` — оптимизация списка и форм редактирования товаров в админке.

- **`select_related('brand', 'category')`** — подгружает связанные объекты по **ForeignKey** одним SQL-запросом (JOIN), без N+1 запросов к бренду и категории для каждого товара.

- **`prefetch_related(...)`** — для **обратных FK**, **M2M** и **through**:
  - `variants` — варианты товара;
  - `tags` — теги через M2M;
  - `Prefetch('product_tags', queryset=ProductTag.objects.select_related('tag'))` — строки связи с подгрузкой `Tag`;
  - `Prefetch('similar_from_links', queryset=ProductSimilar.objects.select_related('to_product', ...))` — похожие товары.

Кратко для защиты: `select_related` — для «прямых» ForeignKey в одном запросе; `prefetch_related` — для коллекций связанных объектов и M2M (отдельные запросы, но без N+1 при обходе в шаблонах и инлайнах админки).

## 5. Файлы

| Файл | Назначение |
|------|------------|
| `shop/models.py` | Tag, ProductTag, ProductSimilar, поля `tags`, `similar_products` |
| `shop/admin.py` | `ProductAdmin.get_queryset` с `select_related` / `prefetch_related`, инлайны тегов и похожих товаров |
| `config/urls.py` | Корень `/` перенаправляет в админку (`admin:index`) |
| `shop/migrations/0002_*.py` | Миграция лабы 4 |

После клонирования репозитория: `pip install -r requirements.txt`, `python manage.py migrate`, при необходимости `python manage.py fill_fake_data`.
Вход в демонстрацию: **http://127.0.0.1:8000/admin/** (создайте суперпользователя: `python manage.py createsuperuser`).

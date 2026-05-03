# Ответы для защиты (Лаба 3, актуально под текущий проект)

Формат ниже:  
1) **Где прописано** (файл),  
2) **Где используется**,  
3) **Что сказать на защите**.

---

## 1. Что показать в проекте

### 1.1 `timezone` (минимум 3 примера)

**Где прописано:**
- `shop/models.py` — импорт `from django.utils import timezone`.
- `shop/models.py` — `Product.created_at = models.DateTimeField(..., default=timezone.now)`.
- `shop/models.py` — `Order.order_date = models.DateTimeField(..., default=timezone.now)`.
- `shop/managers.py` — `now = timezone.now()` в `PromoCodeQuerySet.active_now()`.
- `shop/managers.py` — `timezone.now() - timezone.timedelta(days=30)` в `ProductManager.created_after()`.

**Где используется:**
- Дата создания товара (`Product.created_at`) для выборки “новых/старых” товаров.
- Дата заказа (`Order.order_date`) для сортировки и фильтрации заказов.
- Окно действия промокода (`valid_from/valid_until`) в `PromoCodeManager.active_now()`.

**Что сказать:**  
«В проекте время беру через `django.utils.timezone`: в моделях ставлю `default=timezone.now`, а в менеджерах использую `timezone.now()` для вычисления актуальных выборок. Это корректно при `USE_TZ=True`».

---

### 1.2 `class Meta: ordering`

**Где прописано:** `shop/models.py` в `class Meta` у моделей.

**Где используется:**
- `Product` — `ordering = ['-created_at']` (новые товары выше).
- `Order` — `ordering = ['-order_date']` (новые заказы выше).
- Справочники (`Brand`, `Category`, `Size`, `Color`, `Tag`) — сортировка по имени.

**Что сказать:**  
«`Meta.ordering` задает порядок по умолчанию для QuerySet без явного `order_by()`».

---

### 1.3 `choices` в моделях

**Где прописано:** `shop/models.py`.

**Где используется:**
- `PromoCode.DiscountType` + поле `discount_type` (`percent` / `fixed`).
- `Order.Status` + поле `status` (`pending`, `paid`, `shipped`, `delivered`, `cancelled`).
- В админке отображаются человекочитаемые подписи значений.

**Что сказать:**  
«`choices` ограничивает допустимые значения и делает понятное отображение в админке».

---

### 1.4 `related_name`

**Где прописано:** `shop/models.py` в `ForeignKey`/`ManyToManyField`.

**Где используется:**
- `Product.brand` с `related_name='products'` -> `brand.products`.
- `OrderItem.order` с `related_name='items'` -> `order.items`.
- `ProductVariant.product` с `related_name='variants'` -> `product.variants`.
- В `shop/admin.py` это используется в подсчетах/итерации связанных объектов.

**Что сказать:**  
«`related_name` нужен для удобного обратного доступа к связанным записям».

---

### 1.5 `filter()`

**Где прописано/используется:**
- `shop/admin.py` — фильтрация размеров/цветов и вариантов при работе форм админки.
- `shop/managers.py` — `in_stock()`, `created_after()`, `active_now()` реализованы через `filter(...)`.

**Что сказать:**  
«Отдельного публичного view нет, поэтому `filter()` демонстрируется в админ-логике и кастомных менеджерах».

---

### 1.6 Использование `__` (double underscore)

**Где используется:**
- Переход по связи: `product_variant__product__name`, `order__status`.
- Lookup по полю: `created_at__gte`, `valid_from__lte`, `used_count__lt`.
- Примеры есть в `shop/admin.py` и `shop/managers.py`.

**Что сказать:**  
«`__` используется и для перехода по связям, и для lookup-операторов».

---

### 1.7 `exclude()`

**Где использовать в проекте:** в shell/сервисной логике, например:
```python
Order.objects.exclude(status='cancelled')
```

**Что сказать:**  
«`exclude()` возвращает записи, которые НЕ соответствуют условию».

---

### 1.8 `order_by()`

**Где используется:**
- `shop/admin.py` — явные `order_by('name')` в помощниках для списков.
- `shop/models.py` — базовый порядок через `Meta.ordering`.

**Что сказать:**  
«`order_by()` — явная сортировка в запросе, `Meta.ordering` — сортировка по умолчанию».

---

### 1.9 Собственный модельный менеджер

**Где прописано:**
- `shop/managers.py` — `ProductManager`, `PromoCodeManager` и соответствующие `QuerySet`.
- `shop/models.py` — подключение: `objects = ProductManager()` и `objects = PromoCodeManager()`.

**Где используется:**
- `Product.objects.in_stock()`
- `Product.objects.created_after(...)`
- `PromoCode.objects.active_now()`

**Что сказать:**  
«Кастомный менеджер выносит бизнес-фильтры из случайных мест в единый API модели».

---

### 1.10 `get_absolute_url` и `reverse`

**Где прописано:** `shop/models.py`, метод `Product.get_absolute_url`.

**Как используется:**  
Возвращает URL редактирования товара в админке:
```python
return reverse('admin:shop_product_change', args=[self.pk])
```

**Что сказать:**  
«`reverse` собирает URL по имени маршрута, `get_absolute_url` дает стандартный способ получить ссылку на объект».

---

### 1.11 Агрегация и аннотация (3 примера)

Показывать удобно в `python manage.py shell`:

1) `Sum`:
```python
from django.db.models import Sum
Order.objects.exclude(status='cancelled').aggregate(total=Sum('total_amount'))
```

2) `Count` через `aggregate` (один итог по всей выборке):
```python
from django.db.models import Count
Order.objects.aggregate(total_items=Count('items'))
```

3) `Avg + Count` по связи:
```python
from django.db.models import Avg, Count
Category.objects.annotate(
    avg_price=Avg('products__base_price'),
    products_count=Count('products'),
).filter(products_count__gt=0)
```

---

## 2. Ответы на вопросы

### 2.1 Миграции: создание и применение

```bash
python manage.py makemigrations
python manage.py migrate
```

- `makemigrations` создаёт файлы в `shop/migrations/`.
- `migrate` применяет их к БД.

---

### 2.2 QuerySet и менеджеры

- `QuerySet` — ленивый объект запроса (`filter`, `exclude`, `order_by`, `annotate`).
- Менеджер — точка входа (`Model.objects`), где можно дать свои методы.
- В проекте: `ProductManager` и `PromoCodeManager` в `shop/managers.py`.

---

### 2.3 Регулярные выражения в URL

В Django можно использовать `re_path`, пример:
```python
re_path(r'^product/(?P<pk>[0-9]+)/$', views.product_detail, name='product_detail')
```

В текущей версии проекта публичных страниц нет (демо через админку), но синтаксис и принцип остаются теми же.

---

## 3. Что открыть на защите

1. `shop/models.py` — поля, `Meta`, `choices`, `related_name`, `get_absolute_url`.
2. `shop/managers.py` — `timezone.now()`, `filter()`, кастомные менеджеры.
3. `shop/admin.py` — практическое использование связей/фильтрации в админке.
4. `python manage.py shell` — агрегаты и аннотации.

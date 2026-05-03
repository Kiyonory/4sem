from django.db import models
from django.urls import reverse
from django.contrib.auth.models import AbstractUser
from django.utils import timezone
from .managers import ProductManager, PromoCodeManager

# ---------- Для входа в админку (логин/пароль) ----------
class User(AbstractUser):
    class Meta:
        verbose_name = 'Пользователь (админ)'
        verbose_name_plural = 'Пользователи'

    def __str__(self):
        return self.username or self.email

# ---------- 1. Бренды ----------
class Brand(models.Model):
    name = models.CharField('Название', max_length=255)
    description = models.TextField('Описание', blank=True)

    class Meta:
        verbose_name = 'Бренд'
        verbose_name_plural = 'Бренды'
        ordering = ['name']

    def __str__(self):
        return self.name

    def products_count(self):
        return self.products.count()

# ---------- 2. Категории ----------
class Category(models.Model):
    name = models.CharField('Название', max_length=255)
    description = models.TextField('Описание', blank=True)

    class Meta:
        verbose_name = 'Категория'
        verbose_name_plural = 'Категории'
        ordering = ['name']

    def __str__(self):
        return self.name

# ---------- 3. Справочники размеров и цветов ----------
class Size(models.Model):
    name = models.CharField('Название', max_length=50)

    class Meta:
        verbose_name = 'Размер'
        verbose_name_plural = 'Размеры'
        ordering = ['name']

    def __str__(self):
        return self.name

class Color(models.Model):
    name = models.CharField('Название', max_length=100)

    class Meta:
        verbose_name = 'Цвет'
        verbose_name_plural = 'Цвета'
        ordering = ['name']

    def __str__(self):
        return self.name


# ---------- Теги (Лаба 4: ManyToMany через промежуточную модель ProductTag) ----------
class Tag(models.Model):
    """Тег для товара (новинка, скидка, лето и т.д.)."""

    name = models.CharField('Название', max_length=100, unique=True)
    icon = models.ImageField('Иконка', upload_to='shop/tags/', blank=True, null=True)

    class Meta:
        verbose_name = 'Тег'
        verbose_name_plural = 'Теги'
        ordering = ['name']

    def __str__(self):
        return self.name


# ---------- 4. Товар ----------
class Product(models.Model):
    brand = models.ForeignKey(
        Brand,
        on_delete=models.CASCADE,
        related_name='products',
        verbose_name='Бренд',
    )
    category = models.ForeignKey(
        Category,
        on_delete=models.CASCADE,
        related_name='products',
        verbose_name='Категория (тип товара)',
    )
    name = models.CharField('Название', max_length=255)
    description = models.TextField('Описание', blank=True)
    base_price = models.DecimalField(
        'Цена',
        max_digits=10,
        decimal_places=2,
    )
    image_url = models.URLField('URL картинки', max_length=500, blank=True)
    cover_image = models.ImageField(
        'Фото (загрузка файла)',
        upload_to='shop/covers/',
        blank=True,
        null=True,
    )
    specification_file = models.FileField(
        'Файл спецификации (PDF и др.)',
        upload_to='shop/specs/',
        blank=True,
        null=True,
    )
    created_at = models.DateTimeField('Дата добавления', default=timezone.now, editable=False)

    available_sizes = models.ManyToManyField(
        Size,
        related_name='products_available',
        verbose_name='Доступные размеры',
        blank=True,
    )
    available_colors = models.ManyToManyField(
        Color,
        related_name='products_available',
        verbose_name='Доступные цвета',
        blank=True,
    )
    # Лаба 4: M2M через промежуточную модель (доп. поле sort_order)
    tags = models.ManyToManyField(
        Tag,
        through='ProductTag',
        related_name='products',
        verbose_name='Теги',
        blank=True,
    )
    # Лаба 4: M2M на себя через ProductSimilar — нужны through_fields (два FK на Product)
    similar_products = models.ManyToManyField(
        'self',
        through='ProductSimilar',
        symmetrical=False,
        related_name='similar_reverse',
        blank=True,
        through_fields=('from_product', 'to_product'),
        verbose_name='Похожие товары',
    )

    objects = ProductManager()

    class Meta:
        verbose_name = 'Товар'
        verbose_name_plural = 'Товары'
        ordering = ['-created_at']

    def __str__(self):
        return self.name

    def title_with_brand(self):
        """Лаба 5: собственный функциональный метод модели (как в учебнике, ~стр. 410)."""
        return f'{self.brand.name} — {self.name}'

    def get_absolute_url(self):
        return reverse('admin:shop_product_change', args=[self.pk])


class ProductTag(models.Model):
    """Связь товар ↔ тег с порядком отображения (through для tags)."""

    product = models.ForeignKey(Product, on_delete=models.CASCADE, related_name='product_tags', verbose_name='Товар')
    tag = models.ForeignKey(Tag, on_delete=models.CASCADE, related_name='product_tags', verbose_name='Тег')
    sort_order = models.PositiveSmallIntegerField('Порядок', default=0)

    class Meta:
        verbose_name = 'Тег товара'
        verbose_name_plural = 'Теги товаров'
        ordering = ['sort_order', 'pk']
        unique_together = [['product', 'tag']]

    def __str__(self):
        return f'{self.product_id} — {self.tag}'


class ProductSimilar(models.Model):
    """Связь «похожий товар» (through для similar_products; два FK на Product → through_fields)."""

    from_product = models.ForeignKey(
        Product,
        on_delete=models.CASCADE,
        related_name='similar_from_links',
        verbose_name='Товар',
    )
    to_product = models.ForeignKey(
        Product,
        on_delete=models.CASCADE,
        related_name='similar_to_links',
        verbose_name='Похожий на',
    )
    notes = models.CharField('Заметка', max_length=200, blank=True)

    class Meta:
        verbose_name = 'Похожий товар'
        verbose_name_plural = 'Похожие товары'
        unique_together = [['from_product', 'to_product']]

    def __str__(self):
        return f'{self.from_product_id} → {self.to_product_id}'


# ---------- 5. Вариант товара ----------
class ProductVariant(models.Model):
    product = models.ForeignKey(
        Product,
        on_delete=models.CASCADE,
        related_name='variants',
        verbose_name='Товар',
    )
    size = models.ForeignKey(Size, on_delete=models.PROTECT, related_name='product_variants', verbose_name='Размер')
    color = models.ForeignKey(Color, on_delete=models.PROTECT, related_name='product_variants', verbose_name='Цвет')
    stock_quantity = models.PositiveIntegerField('Остаток', default=0)

    class Meta:
        verbose_name = 'Вариант товара'
        verbose_name_plural = 'Варианты товаров'
        ordering = ['product', 'size', 'color']
        unique_together = [['product', 'size', 'color']]

    def __str__(self):
        return f'{self.product.name} — {self.size.name} / {self.color.name}'

    @property
    def effective_price(self):
        return self.product.base_price

# ---------- 6. Промокод ----------
class PromoCode(models.Model):
    class DiscountType(models.TextChoices):
        PERCENT = 'percent', 'Процент'
        FIXED = 'fixed', 'Фиксированная сумма'

    code = models.CharField('Код', max_length=50, unique=True)
    discount_type = models.CharField('Тип скидки', max_length=20, choices=DiscountType.choices)
    discount_value = models.DecimalField('Значение скидки', max_digits=10, decimal_places=2)
    valid_from = models.DateTimeField('Действует с', default=timezone.now)
    valid_until = models.DateTimeField('Действует до', null=True, blank=True)
    max_uses = models.PositiveIntegerField('Макс. использований', default=0)
    used_count = models.PositiveIntegerField('Использовано', default=0)
    created_at = models.DateTimeField('Создан', default=timezone.now, editable=False)

    objects = PromoCodeManager()

    class Meta:
        verbose_name = 'Промокод'
        verbose_name_plural = 'Промокоды'
        ordering = ['-created_at']

    def __str__(self):
        return self.code

# ---------- 7. Заказ (имя/email заказчика, позиции, скидка) ----------
class Order(models.Model):
    class Status(models.TextChoices):
        PENDING = 'pending', 'Ожидает'
        PAID = 'paid', 'Оплачен'
        SHIPPED = 'shipped', 'Отправлен'
        DELIVERED = 'delivered', 'Доставлен'
        CANCELLED = 'cancelled', 'Отменён'

    customer_name = models.CharField('Имя заказчика', max_length=255)
    customer_email = models.EmailField('Email заказчика')
    order_date = models.DateTimeField('Дата заказа', default=timezone.now)
    status = models.CharField(
        'Статус',
        max_length=20,
        choices=Status.choices,
        default=Status.PENDING,
    )
    total_amount = models.DecimalField('Итого к оплате', max_digits=12, decimal_places=2, default=0)
    promo_code = models.ForeignKey(
        PromoCode,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='orders',
        verbose_name='Промокод',
    )
    discount_amount = models.DecimalField('Сумма скидки', max_digits=10, decimal_places=2, default=0)

    class Meta:
        verbose_name = 'Заказ'
        verbose_name_plural = 'Заказы'
        ordering = ['-order_date']

    def __str__(self):
        return f'Заказ #{self.pk} — {self.customer_email}'

# ---------- Позиция в заказе ----------
class OrderItem(models.Model):
    order = models.ForeignKey(Order, on_delete=models.CASCADE, related_name='items', verbose_name='Заказ')
    product_variant = models.ForeignKey(
        ProductVariant,
        on_delete=models.PROTECT,
        related_name='order_items',
        verbose_name='Вариант товара',
    )
    quantity = models.PositiveIntegerField('Количество')
    price_at_time = models.DecimalField('Цена за ед.', max_digits=10, decimal_places=2, default=0)

    class Meta:
        verbose_name = 'Позиция заказа'
        verbose_name_plural = 'Позиции заказов'
        ordering = ['order', 'pk']

    def __str__(self):
        return f'{self.order_id} — {self.product_variant} x {self.quantity}'

    def save(self, *args, **kwargs):
        if self.product_variant_id:
            self.price_at_time = self.product_variant.effective_price
        old_quantity = 0
        if self.pk:
            try:
                old_quantity = OrderItem.objects.only('quantity').get(pk=self.pk).quantity
            except OrderItem.DoesNotExist:
                pass
        super().save(*args, **kwargs)
        if self.product_variant_id:
            from django.db.models import F
            from django.db.models.functions import Greatest
            delta = self.quantity - old_quantity
            if delta != 0:
                ProductVariant.objects.filter(pk=self.product_variant_id).update(
                    stock_quantity=Greatest(0, F('stock_quantity') - delta)
                )

    def delete(self, *args, **kwargs):
        if self.product_variant_id and self.quantity:
            from django.db.models import F
            ProductVariant.objects.filter(pk=self.product_variant_id).update(
                stock_quantity=F('stock_quantity') + self.quantity
            )
        super().delete(*args, **kwargs)


# ---------- Лаба 6: демонстрация URLField, update/delete, F (см. shop/lab_reference.py и админку Lab6Scratch) ----------
class Lab6Scratch(models.Model):
    """Временные строки только для демонстрации update()/delete() и F(). Не использовать в бизнес-логике."""

    label = models.CharField('Метка', max_length=100)
    link = models.URLField('Ссылка (URLField)', max_length=500, blank=True)
    counter = models.IntegerField('Счётчик', default=0)

    class Meta:
        verbose_name = 'Лаба 6 (scratch)'
        verbose_name_plural = 'Лаба 6 (scratch)'

    def __str__(self):
        return self.label

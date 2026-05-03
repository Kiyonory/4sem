from collections import OrderedDict
from decimal import Decimal
from io import BytesIO

from django import forms
from django.contrib import admin, messages
from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator
from django.db.models import F, Prefetch
from django.http import HttpResponse, JsonResponse
from django.shortcuts import render
from django.urls import path, reverse
from django.utils.html import format_html
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer

from .lab_reference import get_lab6_demonstration_context
from .pdf_fonts import register_cyrillic_font
from .models import (
    User,
    Brand,
    Category,
    Size,
    Color,
    Tag,
    Product,
    ProductTag,
    ProductSimilar,
    ProductVariant,
    PromoCode,
    Order,
    OrderItem,
    Lab6Scratch,
)

def _get_sizes_for_product(product):
    if product and product.pk:
        qs = product.available_sizes.all()
        if qs.exists():
            return qs.order_by('name')
        return Size.objects.filter(product_variants__product=product).distinct().order_by('name')
    return Size.objects.none()


def _get_colors_for_product(product):
    if product and product.pk:
        qs = product.available_colors.all()
        if qs.exists():
            return qs.order_by('name')
        return Color.objects.filter(product_variants__product=product).distinct().order_by('name')
    return Color.objects.none()


# ---------- Форма варианта: размер/цвет только из доступных для товара ----------
class ProductVariantForm(forms.ModelForm):
    class Meta:
        model = ProductVariant
        fields = '__all__'

    def __init__(self, *args, parent_product=None, **kwargs):
        super().__init__(*args, **kwargs)
        product = parent_product or (self.instance.product if self.instance.pk else None)
        if product:
            self.fields['size'].queryset = _get_sizes_for_product(product)
            self.fields['color'].queryset = _get_colors_for_product(product)


class ProductVariantInlineFormSet(forms.models.BaseInlineFormSet):
    def _construct_form(self, i, **kwargs):
        kwargs['parent_product'] = self.instance
        return super()._construct_form(i, **kwargs)


# ---------- Форма позиции заказа: товар + размер + цвет ----------
class OrderItemForm(forms.ModelForm):
    product = forms.ModelChoiceField(queryset=Product.objects.all().order_by('name'), label='Товар', required=True)
    size = forms.ModelChoiceField(queryset=Size.objects.none(), label='Размер', required=True)
    color = forms.ModelChoiceField(queryset=Color.objects.none(), label='Цвет', required=True)

    class Meta:
        model = OrderItem
        fields = ['quantity']

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields['quantity'].validators.append(
            MinValueValidator(1, message='Количество должно быть не меньше 1.')
        )
        self.fields['quantity'].help_text = 'Минимум 1 шт.'
        product_id = None
        if self.instance and self.instance.pk and self.instance.product_variant_id:
            v = self.instance.product_variant
            product_id = v.product_id
            self.fields['product'].initial = v.product_id
            self.fields['size'].initial = v.size_id
            self.fields['color'].initial = v.color_id
            # При редактировании не требуем заново выбирать товар/размер/цвет — подставим из варианта
            self.fields['product'].required = False
            self.fields['size'].required = False
            self.fields['color'].required = False
        elif self.data and self.prefix:
            product_id = self.data.get('{}-product'.format(self.prefix))
        elif self.initial:
            product_id = self.initial.get('product')
        if product_id:
            try:
                product = Product.objects.get(pk=product_id)
                self.fields['size'].queryset = _get_sizes_for_product(product)
                self.fields['color'].queryset = _get_colors_for_product(product)
            except Product.DoesNotExist:
                self.fields['size'].queryset = Size.objects.none()
                self.fields['color'].queryset = Color.objects.none()
        else:
            self.fields['size'].queryset = Size.objects.none()
            self.fields['color'].queryset = Color.objects.none()
        self.fields = OrderedDict([
            ('product', self.fields['product']),
            ('size', self.fields['size']),
            ('color', self.fields['color']),
            ('quantity', self.fields['quantity']),
        ])

    def clean(self):
        cleaned = super().clean()
        # При редактировании: если товар/размер/цвет не пришли в форме — берём из текущего варианта
        if self.instance and self.instance.pk and self.instance.product_variant_id:
            v = self.instance.product_variant
            if not cleaned.get('product'):
                cleaned['product'] = v.product
            if not cleaned.get('size'):
                cleaned['size'] = v.size
            if not cleaned.get('color'):
                cleaned['color'] = v.color
        # Проверка остатка: нельзя заказать больше, чем есть на складе
        product = cleaned.get('product')
        size = cleaned.get('size')
        color = cleaned.get('color')
        quantity = cleaned.get('quantity')
        if product and size and color and quantity is not None:
            variant = ProductVariant.objects.filter(
                product=product, size=size, color=color
            ).first()
            old_qty = self.instance.quantity if self.instance.pk else 0
            available = (variant.stock_quantity + old_qty) if variant else 0
            if quantity > available:
                raise ValidationError(
                    'На складе доступно %(available)s шт. по выбранному варианту. Уменьшите количество.'
                    % {'available': available}
                )
        return cleaned

    def save(self, commit=True):
        product = self.cleaned_data.get('product')
        size = self.cleaned_data.get('size')
        color = self.cleaned_data.get('color')
        if product and size and color:
            variant, _ = ProductVariant.objects.get_or_create(
                product=product, size=size, color=color, defaults={'stock_quantity': 0}
            )
            self.instance.product_variant = variant
        # иначе оставляем self.instance.product_variant без изменений (редактирование только количества)
        return super().save(commit=commit)


# ========== 1. Бренды ==========
@admin.register(Brand)
class BrandAdmin(admin.ModelAdmin):
    list_display = ['name', 'product_count']
    list_display_links = ['name']
    search_fields = ['name', 'description']

    @admin.display(description='Товаров')
    def product_count(self, obj):
        return obj.products_count()


# ========== 2. Категории ==========
@admin.register(Category)
class CategoryAdmin(admin.ModelAdmin):
    list_display = ['name', 'product_count']
    list_display_links = ['name']
    search_fields = ['name', 'description']

    @admin.display(description='Товаров')
    def product_count(self, obj):
        return obj.products.count()


# ========== 3. Размеры и цвета ==========
@admin.register(Size)
class SizeAdmin(admin.ModelAdmin):
    list_display = ['name', 'variant_count']
    list_display_links = ['name']
    search_fields = ['name']

    @admin.display(description='Вариантов')
    def variant_count(self, obj):
        return obj.product_variants.count()


@admin.register(Color)
class ColorAdmin(admin.ModelAdmin):
    list_display = ['name', 'variant_count']
    list_display_links = ['name']
    search_fields = ['name']

    @admin.display(description='Вариантов')
    def variant_count(self, obj):
        return obj.product_variants.count()


@admin.register(Tag)
class TagAdmin(admin.ModelAdmin):
    list_display = ['name', 'icon_preview']
    list_display_links = ['name']
    search_fields = ['name']
    fields = ['name', 'icon']

    @admin.display(description='Иконка')
    def icon_preview(self, obj):
        if obj.pk and obj.icon:
            return format_html('<img src="{}" width="32" height="32" alt=""/>', obj.icon.url)
        return '—'


@admin.action(description='Скачать PDF по выбранным товарам')
def generate_pdf_catalog(modeladmin, request, queryset):
    """Лаба 5: генерация PDF в админке (по учебнику). Кириллица — через TTF (см. shop/pdf_fonts.py)."""
    buffer = BytesIO()
    doc = SimpleDocTemplate(buffer, pagesize=A4)
    styles = getSampleStyleSheet()
    font_name = register_cyrillic_font()
    if font_name:
        title_style = ParagraphStyle(
            'TitleRu', parent=styles['Title'], fontName=font_name, fontSize=18, leading=22
        )
        body_style = ParagraphStyle(
            'BodyRu', parent=styles['Normal'], fontName=font_name, fontSize=11, leading=14
        )
    else:
        modeladmin.message_user(
            request,
            'Шрифт с кириллицей не найден: русский текст в PDF может быть «квадратами». '
            'Положите DejaVuSans.ttf в shop/fonts/ (см. shop/fonts/README.txt) или откройте PDF на ПК с Arial.',
            level=messages.WARNING,
        )
        title_style = styles['Title']
        body_style = styles['Normal']

    story = [
        Paragraph('Каталог выбранных товаров', title_style),
        Spacer(1, 8 * mm),
    ]
    for p in queryset.select_related('brand', 'category').order_by('name'):
        line = f'{p.title_with_brand()} — {p.base_price} ₽ · {p.category.name}'
        story.append(Paragraph(line, body_style))
        story.append(Spacer(1, 3 * mm))
    doc.build(story)
    buffer.seek(0)
    response = HttpResponse(buffer.read(), content_type='application/pdf')
    response['Content-Disposition'] = 'attachment; filename="catalog.pdf"'
    return response


@admin.action(description='Показать число выбранных товаров')
def show_selected_products_count(modeladmin, request, queryset):
    """Лаба 5: второе действие в админке."""
    modeladmin.message_user(request, f'Выбрано товаров: {queryset.count()}.')


@admin.action(description='Демо Лабы 6 (ORM) для товаров')
def open_lab6_reference_from_product(modeladmin, request, queryset):
    """
    Выполняем демонстрацию ORM и показываем результат прямо в админке.
    Так преподавателю не нужно переходить на отдельный "reference" URL.
    """
    extra = get_lab6_demonstration_context(request, base_qs=queryset)

    selected_names = extra['values_list_flat']
    icontains_result = [p.name for p in extra['icontains_qs']]
    contains_result = [p.name for p in extra['contains_qs']]
    message = (
        'Лаба 6 (ORM) — демонстрация выполнена.\n'
        f"URLField пример: {extra['urlfield_example']}\n"
        f"Ключ: sample_letter='{extra['sample_letter']}'\n"
        f"__icontains: {icontains_result}\n"
        f"__contains: {contains_result}\n"
        f"count(): {extra['products_count']}, exists(pk>0): {extra['products_exist']}, "
        f"exists(бренд='ZZZ_NONEXISTENT'): {extra['brands_exist']}\n"
        f"cache_hit: {extra['cache_hit']}, cached_count: {extra['cached_count']}\n"
        f"F-update counter_after_f: {extra['counter_after_f']}, deleted_count: {extra['deleted_count']}\n"
    )
    modeladmin.message_user(request, message, level=messages.INFO)


# ========== 4. Товары ==========
class ProductTagInline(admin.TabularInline):
    model = ProductTag
    extra = 1
    autocomplete_fields = ['tag']


class ProductSimilarInline(admin.TabularInline):
    model = ProductSimilar
    fk_name = 'from_product'
    extra = 0
    fields = ['to_product', 'notes']


class ProductVariantInline(admin.TabularInline):
    model = ProductVariant
    form = ProductVariantForm
    formset = ProductVariantInlineFormSet
    extra = 0
    readonly_fields = ['stock_display']

    @admin.display(description='Остаток')
    def stock_display(self, obj):
        if obj.pk and obj.stock_quantity == 0:
            return format_html('<span style="color: red;">{}</span>', obj.stock_quantity)
        return obj.stock_quantity


@admin.register(Product)
class ProductAdmin(admin.ModelAdmin):
    list_display = ['name', 'title_brand_short', 'brand', 'category', 'base_price', 'variants_count', 'created_at']
    list_display_links = ['name']
    list_filter = ['brand', 'category']
    search_fields = ['name', 'description']
    readonly_fields = ['created_at']
    filter_horizontal = ['available_sizes', 'available_colors']
    inlines = [ProductVariantInline, ProductTagInline, ProductSimilarInline]
    actions = [generate_pdf_catalog, show_selected_products_count, open_lab6_reference_from_product]

    fieldsets = (
        ('Бренд и категория', {
            'fields': ('brand', 'category'),
            'description': 'Сначала выберите бренд, к которому привязан товар, и тип товара (категорию).',
        }),
        ('Название и цена', {
            'fields': ('name', 'description', 'base_price', 'image_url'),
        }),
        ('Фото и файлы (Лаба 5)', {
            'fields': ('cover_image', 'specification_file'),
            'description': 'Загрузка файлов: обложка (ImageField) и спецификация (FileField).',
        }),
        ('Доступные размеры и цвета', {
            'fields': ('available_sizes', 'available_colors'),
            'description': 'Укажите, какие размеры и цвета бывают у этого товара (для вариантов и заказов).',
        }),
    )

    def get_queryset(self, request):
        qs = super().get_queryset(request)
        # В Django admin при построении списка может применяться defer/only оптимизация.
        # Если поле `brand`/`category` окажется deferred, то select_related вызовет FieldError:
        # "cannot be both deferred and traversed". Снимаем defer, затем делаем select_related.
        qs = qs.defer(None)
        return (
            qs.select_related('brand', 'category')
            .prefetch_related(
                'variants',
                'tags',
                Prefetch(
                    'product_tags',
                    queryset=ProductTag.objects.select_related('tag').order_by('sort_order', 'pk'),
                ),
                Prefetch(
                    'similar_from_links',
                    queryset=ProductSimilar.objects.select_related('to_product', 'to_product__brand'),
                ),
            )
        )

    @admin.display(description='Название с брендом')
    def title_brand_short(self, obj):
        return obj.title_with_brand()

    @admin.display(description='Вариантов')
    def variants_count(self, obj):
        return obj.variants.count()


# Варианты товаров добавляются только на странице товара (таблица внизу). Отдельного раздела в меню нет — так проще.

# ========== 6. Промокоды ==========
@admin.register(PromoCode)
class PromoCodeAdmin(admin.ModelAdmin):
    list_display = ['code', 'discount_type', 'discount_value', 'valid_from', 'valid_until', 'used_count', 'max_uses']
    list_display_links = ['code']
    list_filter = ['discount_type']
    search_fields = ['code']
    readonly_fields = ['used_count', 'created_at']


# ========== 7. Заказы ==========
class OrderItemInline(admin.TabularInline):
    form = OrderItemForm
    model = OrderItem
    extra = 1
    readonly_fields = ['price_at_time', 'subtotal_display']

    @admin.display(description='Сумма')
    def subtotal_display(self, obj):
        if obj.pk:
            return obj.price_at_time * obj.quantity
        return '—'


@admin.register(Order)
class OrderAdmin(admin.ModelAdmin):
    list_display = [
        'id', 'customer_name', 'customer_email', 'order_date', 'status',
        'subtotal_display', 'discount_amount', 'total_amount', 'promo_code',
    ]
    list_display_links = ['id', 'customer_name']
    list_filter = ['status', 'order_date']
    date_hierarchy = 'order_date'
    search_fields = ['customer_name', 'customer_email']
    readonly_fields = ['order_date', 'subtotal_readonly', 'discount_amount', 'total_amount']
    raw_id_fields = ['promo_code']
    inlines = [OrderItemInline]
    change_form_template = 'admin/shop/order/change_form.html'

    fieldsets = (
        (None, {
            'fields': ('customer_name', 'customer_email', 'order_date', 'status'),
        }),
        ('Итог', {
            'fields': ('subtotal_readonly', 'promo_code', 'discount_amount', 'total_amount'),
        }),
    )

    def save_model(self, request, obj, form, change):
        old_promo_id = None
        if change and obj.pk:
            old_promo_id = Order.objects.filter(pk=obj.pk).values_list('promo_code_id', flat=True).first()
        super().save_model(request, obj, form, change)
        new_promo_id = obj.promo_code_id
        if old_promo_id != new_promo_id:
            if old_promo_id:
                PromoCode.objects.filter(pk=old_promo_id, used_count__gt=0).update(used_count=F('used_count') - 1)
            if new_promo_id:
                PromoCode.objects.filter(pk=new_promo_id).update(used_count=F('used_count') + 1)

    def change_view(self, request, object_id=None, form_url='', extra_context=None):
        extra_context = extra_context or {}
        base = request.path.rstrip('/')
        if base.endswith('/add'):
            base = base[:-4]
        elif '/change/' in base:
            base = base.split('/change/')[0]
        extra_context['product_variant_options_url'] = request.build_absolute_uri(base + '/product-variant-options/')
        return super().change_view(request, object_id, form_url, extra_context)

    def add_view(self, request, form_url='', extra_context=None):
        extra_context = extra_context or {}
        base = request.path.rstrip('/')
        if base.endswith('/add'):
            base = base[:-4]
        extra_context['product_variant_options_url'] = request.build_absolute_uri(base + '/product-variant-options/')
        return super().add_view(request, form_url, extra_context)

    def get_urls(self):
        urls = super().get_urls()
        return [
            path(
                'product-variant-options/',
                self.admin_site.admin_view(self._product_variant_options),
                name='shop_order_variant_options',
            ),
        ] + urls

    def _product_variant_options(self, request):
        product_id = request.GET.get('product_id')
        if not product_id:
            return JsonResponse({'sizes': [], 'colors': []})
        try:
            product = Product.objects.get(pk=product_id)
        except Product.DoesNotExist:
            return JsonResponse({'sizes': [], 'colors': []})
        sizes = list(_get_sizes_for_product(product).values('id', 'name'))
        colors = list(_get_colors_for_product(product).values('id', 'name'))
        return JsonResponse({'sizes': sizes, 'colors': colors})

    def subtotal_readonly(self, obj):
        if obj and obj.pk:
            items = list(obj.items.all())
            if items:
                s = sum((i.price_at_time * i.quantity) for i in items)
                return f'{s} ₽'
        return '0 ₽ (добавьте позиции ниже)'
    subtotal_readonly.short_description = 'Подытог'

    @admin.display(description='Подытог')
    def subtotal_display(self, obj):
        if obj.pk:
            items = list(obj.items.all())
            if items:
                return sum((i.price_at_time * i.quantity) for i in items)
        return '—'

    def save_related(self, request, form, formsets, change):
        super().save_related(request, form, formsets, change)
        self._recalculate_order_totals(form.instance)

    def _recalculate_order_totals(self, order):
        items = list(order.items.all())
        subtotal = sum((item.price_at_time * item.quantity) for item in items) if items else Decimal('0')
        discount = Decimal('0')
        if order.promo_code_id and subtotal > 0:
            promo = order.promo_code
            if promo.discount_type == PromoCode.DiscountType.PERCENT:
                discount = subtotal * (promo.discount_value / Decimal('100'))
            else:
                discount = min(promo.discount_value, subtotal)
        order.discount_amount = discount.quantize(Decimal('0.01'))
        order.total_amount = (subtotal - discount).quantize(Decimal('0.01'))
        order.save(update_fields=['total_amount', 'discount_amount'])


@admin.register(OrderItem)
class OrderItemAdmin(admin.ModelAdmin):
    list_display = ['order', 'product_variant', 'quantity', 'price_at_time', 'subtotal']
    list_display_links = ['order', 'product_variant']
    list_filter = ['order__status']
    search_fields = ['order__customer_email', 'product_variant__product__name']
    raw_id_fields = ['order', 'product_variant']

    @admin.display(description='Сумма')
    def subtotal(self, obj):
        if obj.pk:
            return obj.price_at_time * obj.quantity
        return '—'


@admin.register(Lab6Scratch)
class Lab6ScratchAdmin(admin.ModelAdmin):
    list_display = ['lab6_reference_link', 'label', 'link', 'counter']

    def has_module_permission(self, request):
        # Скрываем модель из левой навигации админки:
        # демонстрация делается через отдельную страницу reference/,
        # а магазин одежды при защите выглядит чище.
        return False

    def get_urls(self):
        urls = super().get_urls()
        return [
            path(
                'reference/',
                self.admin_site.admin_view(self.lab6_reference_view),
                name='shop_lab6_reference',
            ),
        ] + urls

    def lab6_reference_view(self, request):
        extra = get_lab6_demonstration_context(request)
        context = {
            **self.admin_site.each_context(request),
            **extra,
            'title': 'Лаба 6 — демонстрация ORM',
            'opts': self.model._meta,
        }
        return render(request, 'admin/shop/lab6_reference.html', context)

    @admin.display(description='Лаба 6')
    def lab6_reference_link(self, obj):
        url = reverse('admin:shop_lab6_reference')
        return format_html('<a href="{}">Демонстрация ORM</a>', url)


# ---------- Пользователи (только для входа в админку) ----------
@admin.register(User)
class UserAdmin(admin.ModelAdmin):
    list_display = ['username', 'email', 'is_active', 'is_staff']
    list_display_links = ['username']
    list_filter = ['is_active', 'is_staff']
    search_fields = ['username', 'email']

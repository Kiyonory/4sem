"""
Заполнение БД тестовыми данными с помощью Faker.
Запуск: python manage.py fill_fake_data [--clear]
  --clear  — перед заполнением удалить все данные (кроме пользователей)
"""
from decimal import Decimal
import random
from django.core.management.base import BaseCommand
from django.utils import timezone
from faker import Faker

from shop.models import (
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
)


# Фиксированные справочники для правдоподобных данных
CATEGORY_NAMES = [
    'Футболка', 'Брюки', 'Куртка', 'Платье', 'Рубашка', 'Свитер', 'Джинсы', 'Шорты',
]
SIZE_NAMES = ['XS', 'S', 'M', 'L', 'XL', '42', '44', '46', '48']
COLOR_NAMES = [
    'Чёрный', 'Белый', 'Серый', 'Синий', 'Красный', 'Зелёный', 'Бежевый', 'Коричневый',
]
# Бренды одежды (реальные названия)
BRAND_NAMES = [
    'Nike', 'Adidas', 'Zara', 'H&M', 'Uniqlo', 'Puma', 'Reebok', 'Lacoste',
    'Gucci', 'Calvin Klein', 'Tommy Hilfiger', 'Levi\'s', 'Massimo Dutti', 'Reserved',
]
# Названия одежды для товаров
PRODUCT_NAMES = [
    'Футболка базовая', 'Футболка с принтом', 'Футболка поло', 'Футболка оверсайз',
    'Брюки чинос', 'Брюки карго', 'Брюки классические', 'Брюки зауженные',
    'Куртка ветровка', 'Куртка демисезонная', 'Куртка утеплённая', 'Парка',
    'Платье летнее', 'Платье коктейльное', 'Платье макси', 'Сарафан',
    'Рубашка оксфорд', 'Рубашка фланелевая', 'Рубашка с коротким рукавом',
    'Свитер с воротником', 'Свитер с V-образным вырезом', 'Кардиган', 'Водолазка',
    'Джинсы скинни', 'Джинсы прямые', 'Джинсы бойфренды', 'Джинсы с высокой посадкой',
    'Шорты бермуды', 'Шорты спортивные', 'Шорты джинсовые', 'Худи базовое',
    'Толстовка с капюшоном', 'Бомбер', 'Жилетка стёганая',
]
TAG_NAMES = ['новинка', 'скидка', 'лето', 'зима', 'хит', 'онлайн']


class Command(BaseCommand):
    help = 'Заполняет БД тестовыми данными (Faker). Опция --clear удаляет старые данные.'

    def add_arguments(self, parser):
        parser.add_argument(
            '--clear',
            action='store_true',
            help='Удалить все данные перед заполнением (кроме пользователей)',
        )

    def handle(self, *args, **options):
        fake = Faker('ru_RU')
        Faker.seed(42)
        random.seed(42)

        if options['clear']:
            self._clear_data()

        self.stdout.write('Создание справочников: размеры, цвета, категории, бренды, теги...')
        sizes = self._create_sizes()
        colors = self._create_colors()
        categories = self._create_categories(fake)
        brands = self._create_brands(fake)
        tags = self._create_tags()

        self.stdout.write('Создание товаров и вариантов...')
        products, variants = self._create_products_and_variants(fake, brands, categories, sizes, colors, tags)

        self.stdout.write('Создание промокодов и заказов...')
        promos = self._create_promos(fake)
        self._create_orders_and_items(fake, promos, variants)

        self.stdout.write(self.style.SUCCESS('Готово. Тестовые данные созданы.'))

    def _clear_data(self):
        """Удаление в порядке, обратном зависимостям (сначала дочерние таблицы)."""
        OrderItem.objects.all().delete()
        Order.objects.all().delete()
        ProductVariant.objects.all().delete()
        Product.objects.all().delete()
        Tag.objects.all().delete()
        PromoCode.objects.all().delete()
        Size.objects.all().delete()
        Color.objects.all().delete()
        Category.objects.all().delete()
        Brand.objects.all().delete()
        self.stdout.write('  Старые данные удалены.')

    def _create_sizes(self):
        created = []
        for name in SIZE_NAMES:
            s, _ = Size.objects.get_or_create(name=name)
            created.append(s)
        return created

    def _create_colors(self):
        created = []
        for name in COLOR_NAMES:
            c, _ = Color.objects.get_or_create(name=name)
            created.append(c)
        return created

    def _create_categories(self, fake):
        created = []
        for name in CATEGORY_NAMES:
            cat, _ = Category.objects.get_or_create(
                name=name,
                defaults={'description': fake.sentence() if random.random() > 0.5 else ''},
            )
            created.append(cat)
        return created

    def _create_brands(self, fake):
        created = []
        # Берём случайные бренды одежды из списка (без повторов)
        chosen = random.sample(BRAND_NAMES, k=min(8, len(BRAND_NAMES)))
        for name in chosen:
            b, _ = Brand.objects.get_or_create(
                name=name,
                defaults={'description': fake.paragraph() if random.random() > 0.5 else ''},
            )
            created.append(b)
        return created

    def _create_tags(self):
        created = []
        for name in TAG_NAMES:
            t, _ = Tag.objects.get_or_create(name=name)
            created.append(t)
        return created

    def _create_products_and_variants(self, fake, brands, categories, sizes, colors, tags):
        products = []
        all_variants = []
        # Случайные названия одежды без повторов (если список короче 25 — с суффиксом)
        names_pool = random.sample(PRODUCT_NAMES, k=min(25, len(PRODUCT_NAMES)))
        while len(names_pool) < 25:
            names_pool.append(f"{random.choice(PRODUCT_NAMES)} ({len(names_pool) + 1})")
        for i in range(25):
            brand = random.choice(brands)
            category = random.choice(categories)
            name = names_pool[i][:255]
            product = Product.objects.create(
                brand=brand,
                category=category,
                name=name,
                description=fake.paragraph() if random.random() > 0.5 else '',
                base_price=Decimal(str(round(random.uniform(500, 15000), 2))),
            )
            # Подключаем часть размеров и цветов к товару
            prod_sizes = random.sample(sizes, k=min(random.randint(2, 5), len(sizes)))
            prod_colors = random.sample(colors, k=min(random.randint(2, 5), len(colors)))
            product.available_sizes.set(prod_sizes)
            product.available_colors.set(prod_colors)
            for i, tag in enumerate(random.sample(tags, k=min(random.randint(1, 4), len(tags)))):
                ProductTag.objects.get_or_create(
                    product=product, tag=tag, defaults={'sort_order': i}
                )
            products.append(product)

            # Варианты только для комбинаций размер+цвет из доступных
            for size in prod_sizes:
                for color in prod_colors:
                    stock = random.randint(5, 50)
                    v, _ = ProductVariant.objects.get_or_create(
                        product=product,
                        size=size,
                        color=color,
                        defaults={'stock_quantity': stock},
                    )
                    if not _:
                        v.stock_quantity = stock
                        v.save(update_fields=['stock_quantity'])
                    all_variants.append(v)

        # Похожие товары (ProductSimilar, through_fields)
        for _ in range(20):
            a, b = random.sample(products, 2)
            if a.pk != b.pk:
                ProductSimilar.objects.get_or_create(
                    from_product=a, to_product=b, defaults={'notes': ''}
                )

        return products, all_variants

    def _create_promos(self, fake):
        created = []
        for i in range(5):
            code = fake.lexify(text='??????').upper() or f"PROMO{i}"
            if PromoCode.objects.filter(code=code).exists():
                code = f"PROMO{fake.random_number(digits=4)}"
            promo_type = random.choice([PromoCode.DiscountType.PERCENT, PromoCode.DiscountType.FIXED])
            value = Decimal(str(round(random.uniform(5, 25), 2))) if promo_type == PromoCode.DiscountType.PERCENT else Decimal(str(round(random.uniform(100, 500), 2)))
            valid_from = timezone.now() - timezone.timedelta(days=random.randint(0, 30))
            valid_until = timezone.now() + timezone.timedelta(days=random.randint(30, 90)) if random.random() > 0.3 else None
            p = PromoCode.objects.create(
                code=code,
                discount_type=promo_type,
                discount_value=value,
                valid_from=valid_from,
                valid_until=valid_until,
                max_uses=random.choice([0, 0, 10, 100]),
            )
            created.append(p)
        return created

    def _create_orders_and_items(self, fake, promos, variants):
        for _ in range(30):
            customer_name = fake.name()
            customer_email = fake.email()
            order_date = timezone.now() - timezone.timedelta(days=random.randint(0, 60))
            status = random.choice([
                Order.Status.PENDING, Order.Status.PENDING,
                Order.Status.PAID, Order.Status.SHIPPED, Order.Status.DELIVERED, Order.Status.CANCELLED,
            ])
            promo = random.choice([None, None, random.choice(promos)])
            order = Order.objects.create(
                customer_name=customer_name,
                customer_email=customer_email,
                order_date=order_date,
                status=status,
                promo_code=promo,
            )
            # 1–4 позиции в заказе, по разным вариантам с достаточным остатком
            chosen = random.sample(variants, k=min(random.randint(1, 4), len(variants)))
            for v in chosen:
                qty = random.randint(1, min(3, v.stock_quantity) or 1)
                if qty < 1:
                    qty = 1
                OrderItem.objects.create(
                    order=order,
                    product_variant=v,
                    quantity=qty,
                )
        # Пересчёт итогов заказов (подытог, скидка, итого)
        for order in Order.objects.all():
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

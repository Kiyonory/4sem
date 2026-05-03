# Lab 2: собственный модельный менеджер
from django.db import models
from django.db.models import F, Q
from django.utils import timezone


class ProductQuerySet(models.QuerySet):
    """Набор запросов для товаров: методы для фильтрации."""

    def in_stock(self):
        """Товары, у которых есть хотя бы один вариант с остатком > 0."""
        return self.filter(variants__stock_quantity__gt=0).distinct()

    def created_after(self, dt):
        """Товары, созданные после указанной даты."""
        return self.filter(created_at__gte=dt)


class ProductManager(models.Manager):
    """Собственный менеджер для Product. Использование: Product.objects.in_stock()."""

    def get_queryset(self):
        return ProductQuerySet(self.model, using=self._db)

    def in_stock(self):
        return self.get_queryset().in_stock()

    def created_after(self, dt=None):
        dt = dt or timezone.now() - timezone.timedelta(days=30)
        return self.get_queryset().created_after(dt)


class PromoCodeQuerySet(models.QuerySet):
    """Промокоды, действующие в данный момент."""

    def active_now(self):
        now = timezone.now()
        return self.filter(valid_from__lte=now).filter(
            Q(valid_until__isnull=True) | Q(valid_until__gte=now)
        ).filter(Q(max_uses=0) | Q(used_count__lt=F('max_uses')))


class PromoCodeManager(models.Manager):
    def get_queryset(self):
        return PromoCodeQuerySet(self.model, using=self._db)

    def active_now(self):
        return self.get_queryset().active_now()

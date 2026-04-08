import { NotFoundException, BadRequestException } from '@nestjs/common';
import { OrderService } from './r2-OrderService';

describe('OrderService', () => {
  let service: OrderService;
  let prisma: any;
  let redis: any;
  let emailService: any;
  let paymentGateway: any;

  const ORG_ID = 'test-org-123';
  const ORDER_ID = 'order-abc';

  beforeEach(() => {
    prisma = {
      order: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
        updateMany: jest.fn(),
        groupBy: jest.fn(),
      },
      orderItem: {
        deleteMany: jest.fn(),
      },
      $transaction: jest.fn((fn) => fn(prisma)),
    };

    redis = {
      get: jest.fn(),
      set: jest.fn(),
      del: jest.fn(),
      keys: jest.fn().mockResolvedValue([]),
    };

    emailService = {
      sendShippingNotification: jest.fn().mockResolvedValue(undefined),
    };

    paymentGateway = {};

    service = new OrderService(prisma, redis, emailService, paymentGateway);
    jest.clearAllMocks();
  });

  describe('findAll', () => {
    it('returns cached data if available', async () => {
      const cachedData = [{ id: '1' }];
      redis.get.mockResolvedValue(JSON.stringify(cachedData));

      const result = await service.findAll({}, ORG_ID);

      expect(result).toEqual(cachedData);
      expect(prisma.order.findMany).not.toHaveBeenCalled();
    });

    it('fetches from DB and caches if not in Redis', async () => {
      const dbData = [{ id: '1' }];
      redis.get.mockResolvedValue(null);
      prisma.order.findMany.mockResolvedValue(dbData);

      const result = await service.findAll({ status: 'pending' }, ORG_ID);

      expect(result).toEqual(dbData);
      expect(prisma.order.findMany).toHaveBeenCalledWith(expect.objectContaining({
        where: expect.objectContaining({ organizationId: ORG_ID, status: 'pending' })
      }));
      expect(redis.set).toHaveBeenCalled();
    });
  });

  describe('findById', () => {
    it('returns the order if it exists and belongs to the org', async () => {
      const order = { id: ORDER_ID, organizationId: ORG_ID };
      prisma.order.findUnique.mockResolvedValue(order);

      const result = await service.findById(ORDER_ID, ORG_ID);

      expect(result).toEqual(order);
    });

    it('throws NotFoundException if order does not exist', async () => {
      prisma.order.findUnique.mockResolvedValue(null);

      await expect(service.findById('invalid', ORG_ID)).rejects.toThrow(NotFoundException);
    });

    it('throws NotFoundException if order belongs to a different org', async () => {
      prisma.order.findUnique.mockResolvedValue({ id: ORDER_ID, organizationId: 'other-org' });

      await expect(service.findById(ORDER_ID, ORG_ID)).rejects.toThrow(NotFoundException);
    });
  });

  describe('create', () => {
    it('creates an order in a transaction and invalidates cache', async () => {
      const dto = {
        customerId: 'cust-1',
        currency: 'USD',
        lineItems: [{ productId: 'p1', quantity: 2, unitPrice: 10.50 }]
      };
      prisma.order.create.mockResolvedValue({ id: 'new-id', total: 21 });

      const result = await service.create(dto, ORG_ID);

      expect(prisma.$transaction).toHaveBeenCalled();
      expect(prisma.order.create).toHaveBeenCalledWith(expect.objectContaining({
        data: expect.objectContaining({ total: 21 })
      }));
      expect(redis.keys).toHaveBeenCalledWith(`orders:${ORG_ID}:*`);
    });

    it('throws BadRequestException if line items have negative values', async () => {
      const dto = {
        customerId: 'cust-1',
        currency: 'USD',
        lineItems: [{ productId: 'p1', quantity: -1, unitPrice: 10 }]
      };

      await expect(service.create(dto, ORG_ID)).rejects.toThrow(BadRequestException);
    });
  });

  describe('updateStatus', () => {
    it('successfully transitions from pending to confirmed', async () => {
      const order = { id: ORDER_ID, organizationId: ORG_ID, status: 'pending' };
      prisma.order.findUnique.mockResolvedValue(order);
      prisma.order.update.mockResolvedValue({ ...order, status: 'confirmed' });

      await service.updateStatus(ORDER_ID, 'confirmed', ORG_ID);

      expect(prisma.order.update).toHaveBeenCalledWith(expect.objectContaining({
        where: { id: ORDER_ID, status: 'pending' },
        data: { status: 'confirmed' }
      }));
    });

    it('throws BadRequestException for invalid transition', async () => {
      const order = { id: ORDER_ID, organizationId: ORG_ID, status: 'shipped' };
      prisma.order.findUnique.mockResolvedValue(order);

      await expect(service.updateStatus(ORDER_ID, 'pending', ORG_ID)).rejects.toThrow(BadRequestException);
    });

    it('sends email notification when status becomes shipped', async () => {
      const order = { id: ORDER_ID, organizationId: ORG_ID, status: 'processing' };
      prisma.order.findUnique.mockResolvedValue(order);
      prisma.order.update.mockResolvedValue({ ...order, status: 'shipped' });

      await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);

      expect(emailService.sendShippingNotification).toHaveBeenCalled();
    });

    it('logs error if email sending fails but does not crash', async () => {
      const consoleSpy = jest.spyOn(console, 'error').mockImplementation();
      const order = { id: ORDER_ID, organizationId: ORG_ID, status: 'processing' };
      prisma.order.findUnique.mockResolvedValue(order);
      prisma.order.update.mockResolvedValue({ ...order, status: 'shipped' });
      emailService.sendShippingNotification.mockRejectedValue(new Error('Email failed'));

      await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);

      expect(consoleSpy).toHaveBeenCalledWith(expect.stringContaining('Failed to send shipping email'), expect.anything());
      consoleSpy.mockRestore();
    });
  });

  describe('calculateMonthlyRevenue', () => {
    it('aggregates revenue by currency for the given month', async () => {
      const month = new Date('2026-03-15');
      prisma.order.groupBy.mockResolvedValue([
        { currency: 'USD', _sum: { total: 100 } }
      ]);

      const result = await service.calculateMonthlyRevenue(month, ORG_ID);

      expect(result).toEqual([{ currency: 'USD', total: 100 }]);
      expect(prisma.order.groupBy).toHaveBeenCalledWith(expect.objectContaining({
        where: expect.objectContaining({
          createdAt: {
            gte: new Date(Date.UTC(2026, 2, 1)),
            lt: new Date(Date.UTC(2026, 3, 1))
          }
        })
      }));
    });
  });

  describe('bulkUpdateStatus', () => {
    it('updates only orders with valid transitions', async () => {
      const orders = [
        { id: 'o1', status: 'pending' }, // valid
        { id: 'o2', status: 'shipped' }, // invalid for 'confirmed'
      ];
      prisma.order.findMany.mockResolvedValue(orders);
      prisma.order.updateMany.mockResolvedValue({ count: 1 });

      const count = await service.bulkUpdateStatus(['o1', 'o2'], 'confirmed', ORG_ID);

      expect(count).toBe(1);
      expect(prisma.order.updateMany).toHaveBeenCalledWith(expect.objectContaining({
        where: { id: { in: ['o1'] } }
      }));
    });
  });

  describe('getOrdersForExport', () => {
    it('applies filters and bounds by 10000', async () => {
      await service.getOrdersForExport({ status: 'shipped' }, ORG_ID);

      expect(prisma.order.findMany).toHaveBeenCalledWith(expect.objectContaining({
        where: expect.objectContaining({ status: 'shipped', organizationId: ORG_ID }),
        take: 10000
      }));
    });
  });

  describe('deleteOrder', () => {
    it('deletes order and items in a transaction', async () => {
      prisma.order.findUnique.mockResolvedValue({ id: ORDER_ID, organizationId: ORG_ID });

      await service.deleteOrder(ORDER_ID, ORG_ID);

      expect(prisma.orderItem.deleteMany).toHaveBeenCalled();
      expect(prisma.order.delete).toHaveBeenCalled();
      expect(redis.keys).toHaveBeenCalled();
    });
  });
});

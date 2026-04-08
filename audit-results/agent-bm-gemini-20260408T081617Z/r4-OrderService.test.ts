import { NotFoundException, BadRequestException } from '@nestjs/common';
import { OrderService } from './r2-OrderService';

describe('OrderService', () => {
  let service: OrderService;
  let prisma: any;
  let txMock: any;
  let redis: any;
  let emailService: any;
  let paymentGateway: any;

  const ORG_ID = 'test-org-123';
  const ORDER_ID = 'order-abc';

  beforeEach(() => {
    txMock = {
      order: {
        create: jest.fn(),
        update: jest.fn(),
        updateMany: jest.fn(),
        findMany: jest.fn(),
        delete: jest.fn(),
      },
      orderItem: {
        deleteMany: jest.fn(),
      },
    };

    prisma = {
      order: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        update: jest.fn(),
        groupBy: jest.fn(),
      },
      $transaction: jest.fn((fn) => fn(txMock)),
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

    it('falls back to DB if Redis get fails or returns invalid JSON', async () => {
      const dbData = [{ id: 'db-1' }];
      redis.get.mockRejectedValue(new Error('Redis down'));
      prisma.order.findMany.mockResolvedValue(dbData);

      const result = await service.findAll({}, ORG_ID);

      expect(result).toEqual(dbData);
      expect(prisma.order.findMany).toHaveBeenCalled();
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
      expect(redis.set).toHaveBeenCalledWith(
        expect.stringContaining(ORG_ID),
        JSON.stringify(dbData),
        300
      );
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
  });

  describe('create', () => {
    it('creates an order in a transaction with calculated total and invalidates cache', async () => {
      const dto = {
        customerId: 'cust-1',
        currency: 'USD',
        lineItems: [{ productId: 'p1', quantity: 2, unitPrice: 10.50 }]
      };
      txMock.order.create.mockResolvedValue({ id: 'new-id', total: 21 });
      redis.keys.mockResolvedValue(['cache-key-1']);

      const result = await service.create(dto, ORG_ID);

      expect(prisma.$transaction).toHaveBeenCalled();
      expect(txMock.order.create).toHaveBeenCalledWith(expect.objectContaining({
        data: expect.objectContaining({ total: 21 }) // 2 * 10.50
      }));
      expect(redis.del).toHaveBeenCalledWith('cache-key-1');
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
    it('successfully transitions from pending to confirmed with optimistic lock', async () => {
      const order = { id: ORDER_ID, organizationId: ORG_ID, status: 'pending' };
      prisma.order.findUnique.mockResolvedValue(order);
      prisma.order.update.mockResolvedValue({ ...order, status: 'confirmed' });

      await service.updateStatus(ORDER_ID, 'confirmed', ORG_ID);

      expect(prisma.order.update).toHaveBeenCalledWith(expect.objectContaining({
        where: { id: ORDER_ID, status: 'pending' },
        data: { status: 'confirmed' }
      }));
    });

    it('throws BadRequestException for invalid transition (e.g. delivered to cancelled)', async () => {
      const order = { id: ORDER_ID, organizationId: ORG_ID, status: 'delivered' };
      prisma.order.findUnique.mockResolvedValue(order);

      await expect(service.updateStatus(ORDER_ID, 'cancelled', ORG_ID)).rejects.toThrow(BadRequestException);
    });

    it('sends email notification with correct params when status becomes shipped', async () => {
      const order = { id: ORDER_ID, organizationId: ORG_ID, status: 'processing' };
      prisma.order.findUnique.mockResolvedValue(order);
      prisma.order.update.mockResolvedValue({ ...order, status: 'shipped' });

      await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);

      expect(emailService.sendShippingNotification).toHaveBeenCalledWith(ORDER_ID, expect.any(String));
    });
  });

  describe('calculateMonthlyRevenue', () => {
    it('aggregates revenue using UTC boundaries', async () => {
      const month = new Date(Date.UTC(2026, 2, 15));
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
    it('updates only orders with valid transitions within transaction', async () => {
      const orders = [
        { id: 'o1', status: 'pending', organizationId: ORG_ID },
        { id: 'o2', status: 'shipped', organizationId: ORG_ID },
      ];
      txMock.order.findMany.mockResolvedValue(orders);
      txMock.order.updateMany.mockResolvedValue({ count: 1 });

      const count = await service.bulkUpdateStatus(['o1', 'o2'], 'confirmed', ORG_ID);

      expect(prisma.$transaction).toHaveBeenCalled();
      expect(count).toBe(1);
      expect(txMock.order.updateMany).toHaveBeenCalledWith(expect.objectContaining({
        where: { id: { in: ['o1'] } }
      }));
    });
  });

  describe('deleteOrder', () => {
    it('deletes order and items and invalidates specifically found keys', async () => {
      prisma.order.findUnique.mockResolvedValue({ id: ORDER_ID, organizationId: ORG_ID });
      redis.keys.mockResolvedValue(['key1', 'key2']);

      await service.deleteOrder(ORDER_ID, ORG_ID);

      expect(txMock.orderItem.deleteMany).toHaveBeenCalled();
      expect(txMock.order.delete).toHaveBeenCalledWith({ where: { id: ORDER_ID } });
      expect(redis.del).toHaveBeenCalledWith('key1');
      expect(redis.del).toHaveBeenCalledWith('key2');
    });
  });
});

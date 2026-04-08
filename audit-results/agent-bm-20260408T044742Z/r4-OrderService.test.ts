import { Test } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { OrderService } from './r2-OrderService';

describe('OrderService', () => {
  let service: OrderService;
  let mockPrisma: any;
  let mockRedis: any;
  let mockEmail: any;
  let mockPayment: any;

  const testOrgId = 'org-123';
  const testOrderId = 'order-456';
  const testCustomerId = 'customer-789';

  beforeEach(async () => {
    // Mock dependencies
    mockPrisma = {
      order: {
        findMany: jest.fn(),
        findFirst: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        delete: jest.fn(),
        update: jest.fn(),
        updateMany: jest.fn(),
      },
      lineItem: {
        createMany: jest.fn(),
        deleteMany: jest.fn(),
        findMany: jest.fn(),
      },
      auditLog: {
        create: jest.fn(),
      },
      $transaction: jest.fn(),
    };

    mockRedis = {
      get: jest.fn(),
      set: jest.fn(),
      del: jest.fn(),
      keys: jest.fn(),
    };

    mockEmail = {
      sendShippedNotification: jest.fn(),
    };

    mockPayment = jest.fn();

    const module = await Test.createTestingModule({
      providers: [
        OrderService,
        { provide: 'PrismaService', useValue: mockPrisma },
        { provide: 'RedisService', useValue: mockRedis },
        { provide: 'EmailService', useValue: mockEmail },
        { provide: 'PaymentGateway', useValue: mockPayment },
      ],
    }).compile();

    service = module.get<OrderService>(OrderService);
  });

  describe('findAll', () => {
    it('should return orders from cache if available', async () => {
      const cachedOrders = [
        { id: 'ord1', status: 'pending', createdAt: new Date('2026-04-01T10:00:00Z'), lineItems: [] },
      ];
      mockRedis.get.mockResolvedValue(JSON.stringify(cachedOrders));

      const result = await service.findAll({ take: 10 }, testOrgId);

      // After JSON.parse, dates are revived back to Date objects
      expect(result[0].id).toEqual('ord1');
      expect(result[0].createdAt).toEqual(jasmine.any(Date));
      expect(mockRedis.get).toHaveBeenCalled();
      expect(mockPrisma.order.findMany).not.toHaveBeenCalled();
    });

    it('should query database and cache results on cache miss', async () => {
      const dbOrders = [
        {
          id: 'ord1',
          organizationId: testOrgId,
          status: 'pending',
          createdAt: new Date(),
          lineItems: [],
        },
      ];
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findMany.mockResolvedValue(dbOrders);

      const result = await service.findAll({ take: 10 }, testOrgId);

      expect(result).toEqual(dbOrders);
      expect(mockRedis.set).toHaveBeenCalledWith(
        expect.stringContaining('findAll'),
        expect.any(String),
        300,
      );
    });

    it('should apply status filter', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findMany.mockResolvedValue([]);

      await service.findAll({ status: 'shipped' }, testOrgId);

      expect(mockPrisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            organizationId: testOrgId,
            status: 'shipped',
          }),
        }),
      );
    });

    it('should apply date range filter', async () => {
      const from = new Date('2026-01-01');
      const to = new Date('2026-01-31');
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findMany.mockResolvedValue([]);

      await service.findAll({ dateRange: { from, to } }, testOrgId);

      expect(mockPrisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            createdAt: { gte: from, lte: to },
          }),
        }),
      );
    });

    it('should respect take and skip pagination', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findMany.mockResolvedValue([]);

      await service.findAll({ take: 25, skip: 50 }, testOrgId);

      expect(mockPrisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          take: 25,
          skip: 50,
        }),
      );
    });
  });

  describe('findById', () => {
    it('should return order from database with lineItems', async () => {
      const order = {
        id: testOrderId,
        organizationId: testOrgId,
        status: 'pending',
        lineItems: [{ id: 'li-1', productId: 'prod-1', quantity: 2, unitPrice: 50 }],
      };
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst.mockResolvedValue(order);

      const result = await service.findById(testOrderId, testOrgId);

      expect(result).toEqual(order);
    });

    it('should throw NotFoundException when order not found', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst.mockResolvedValue(null);

      await expect(service.findById(testOrderId, testOrgId)).rejects.toThrow(
        NotFoundException,
      );
    });

    it('should throw NotFoundException when order belongs to different org', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst.mockResolvedValue(null);

      await expect(service.findById(testOrderId, 'different-org')).rejects.toThrow(
        NotFoundException,
      );
    });

    it('should cache result in Redis', async () => {
      const order = { id: testOrderId, organizationId: testOrgId };
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst.mockResolvedValue(order);

      await service.findById(testOrderId, testOrgId);

      expect(mockRedis.set).toHaveBeenCalledWith(
        expect.stringContaining(testOrderId),
        expect.any(String),
        300,
      );
    });
  });

  describe('create', () => {
    it('should create order with line items in transaction', async () => {
      const dto = {
        customerId: testCustomerId,
        currency: 'USD',
        lineItems: [{ productId: 'prod-1', quantity: 2, unitPrice: 50 }],
      };

      const mockTx = {
        order: {
          create: jest.fn().mockResolvedValue({ id: testOrderId, status: 'pending' }),
          findUnique: jest
            .fn()
            .mockResolvedValue({ id: testOrderId, lineItems: dto.lineItems }),
        },
        lineItem: {
          createMany: jest.fn(),
        },
        auditLog: {
          create: jest.fn(),
        },
      };

      mockPrisma.$transaction.mockImplementation((fn) => fn(mockTx));
      mockRedis.keys.mockResolvedValue([]);

      const result = await service.create(dto, testOrgId);

      expect(mockTx.order.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({
            organizationId: testOrgId,
            customerId: testCustomerId,
            currency: 'USD',
          }),
        }),
      );
      expect(result.lineItems).toEqual(dto.lineItems);
    });

    it('should throw error when lineItems is empty', async () => {
      const dto = {
        customerId: testCustomerId,
        currency: 'USD',
        lineItems: [],
      };

      await expect(service.create(dto, testOrgId)).rejects.toThrow(
        'Invalid CreateOrderDto',
      );
    });

    it('should invalidate cache after creation', async () => {
      const dto = {
        customerId: testCustomerId,
        currency: 'USD',
        lineItems: [{ productId: 'prod-1', quantity: 1, unitPrice: 50 }],
      };

      const mockTx = {
        order: {
          create: jest.fn().mockResolvedValue({ id: testOrderId }),
          findUnique: jest.fn().mockResolvedValue({ id: testOrderId, lineItems: [] }),
        },
        lineItem: { createMany: jest.fn() },
        auditLog: { create: jest.fn() },
      };

      mockPrisma.$transaction.mockImplementation((fn) => fn(mockTx));
      mockRedis.keys.mockResolvedValue(['orders:org-123:findAll:filter1']);

      await service.create(dto, testOrgId);

      expect(mockRedis.del).toHaveBeenCalledWith('orders:org-123:findAll:filter1');
    });

    it('should create audit log on order creation', async () => {
      const dto = {
        customerId: testCustomerId,
        currency: 'USD',
        lineItems: [{ productId: 'prod-1', quantity: 1, unitPrice: 50 }],
      };

      const mockTx = {
        order: {
          create: jest.fn().mockResolvedValue({ id: testOrderId }),
          findUnique: jest.fn().mockResolvedValue({ id: testOrderId, lineItems: [] }),
        },
        lineItem: { createMany: jest.fn() },
        auditLog: { create: jest.fn() },
      };

      mockPrisma.$transaction.mockImplementation((fn) => fn(mockTx));
      mockRedis.keys.mockResolvedValue([]);

      await service.create(dto, testOrgId);

      expect(mockTx.auditLog.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({
            action: 'ORDER_CREATED',
            organizationId: testOrgId,
          }),
        }),
      );
    });
  });

  describe('deleteOrder', () => {
    it('should delete order and line items atomically', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst.mockResolvedValue({ id: testOrderId });

      const mockTx = {
        lineItem: { deleteMany: jest.fn() },
        order: { delete: jest.fn() },
        auditLog: { create: jest.fn() },
      };

      mockPrisma.$transaction.mockImplementation((fn) => fn(mockTx));
      mockRedis.keys.mockResolvedValue([]);

      await service.deleteOrder(testOrderId, testOrgId);

      expect(mockTx.lineItem.deleteMany).toHaveBeenCalledWith({
        where: { orderId: testOrderId },
      });
      expect(mockTx.order.delete).toHaveBeenCalledWith({
        where: { id: testOrderId },
      });
    });

    it('should create audit log on deletion', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst.mockResolvedValue({ id: testOrderId });

      const mockTx = {
        lineItem: { deleteMany: jest.fn() },
        order: { delete: jest.fn() },
        auditLog: { create: jest.fn() },
      };

      mockPrisma.$transaction.mockImplementation((fn) => fn(mockTx));
      mockRedis.keys.mockResolvedValue([]);

      await service.deleteOrder(testOrderId, testOrgId);

      expect(mockTx.auditLog.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({
            action: 'ORDER_DELETED',
            orderId: testOrderId,
          }),
        }),
      );
    });

    it('should invalidate both findById and findAll caches', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst.mockResolvedValue({ id: testOrderId });

      const mockTx = {
        lineItem: { deleteMany: jest.fn() },
        order: { delete: jest.fn() },
        auditLog: { create: jest.fn() },
      };

      mockPrisma.$transaction.mockImplementation((fn) => fn(mockTx));
      // Mock keys to return realistic cache entries
      mockRedis.keys.mockResolvedValue([
        `orders:${testOrgId}:findAll:{"status":"pending"}`,
        `orders:${testOrgId}:findAll:{"take":50}`,
      ]);

      await service.deleteOrder(testOrderId, testOrgId);

      // Should delete both findById key and all findAll keys
      expect(mockRedis.del).toHaveBeenCalledWith(
        expect.stringContaining(`findById`),
      );
      expect(mockRedis.del).toHaveBeenCalledWith(
        `orders:${testOrgId}:findAll:{"status":"pending"}`,
        `orders:${testOrgId}:findAll:{"take":50}`,
      );
    });
  });

  describe('updateStatus', () => {
    it('should transition pending to confirmed', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst.mockResolvedValue({
        id: testOrderId,
        status: 'pending',
      });
      mockPrisma.order.updateMany.mockResolvedValue({ count: 1 });
      mockPrisma.order.findUnique.mockResolvedValue({
        id: testOrderId,
        status: 'confirmed',
      });
      mockRedis.keys.mockResolvedValue([]);

      const result = await service.updateStatus(
        testOrderId,
        'confirmed',
        testOrgId,
      );

      expect(result.status).toBe('confirmed');
    });

    it('should throw error on invalid transition', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst.mockResolvedValue({
        id: testOrderId,
        status: 'delivered',
      });

      await expect(
        service.updateStatus(testOrderId, 'pending', testOrgId),
      ).rejects.toThrow('Cannot transition from delivered to pending');
    });

    it('should send email notification on shipped status', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst.mockResolvedValue({
        id: testOrderId,
        status: 'processing',
        customerId: testCustomerId,
      });
      mockPrisma.order.updateMany.mockResolvedValue({ count: 1 });
      mockPrisma.order.findUnique.mockResolvedValue({
        id: testOrderId,
        status: 'shipped',
      });
      mockRedis.keys.mockResolvedValue([]);
      mockEmail.sendShippedNotification.mockResolvedValue(undefined);

      await service.updateStatus(testOrderId, 'shipped', testOrgId);

      expect(mockEmail.sendShippedNotification).toHaveBeenCalledWith(
        testCustomerId,
        testOrderId,
      );
    });

    it('should handle email notification failure gracefully', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst.mockResolvedValue({
        id: testOrderId,
        status: 'processing',
        customerId: testCustomerId,
      });
      mockPrisma.order.updateMany.mockResolvedValue({ count: 1 });
      mockPrisma.order.findUnique.mockResolvedValue({
        id: testOrderId,
        status: 'shipped',
      });
      mockRedis.keys.mockResolvedValue([]);
      mockEmail.sendShippedNotification.mockRejectedValue(new Error('Email failed'));

      // Should not throw
      await expect(
        service.updateStatus(testOrderId, 'shipped', testOrgId),
      ).resolves.toBeDefined();
    });

    it('should create audit log on status change', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst.mockResolvedValue({
        id: testOrderId,
        status: 'pending',
      });
      mockPrisma.order.updateMany.mockResolvedValue({ count: 1 });
      mockPrisma.order.findUnique.mockResolvedValue({
        id: testOrderId,
        status: 'confirmed',
      });
      mockRedis.keys.mockResolvedValue([]);

      await service.updateStatus(testOrderId, 'confirmed', testOrgId);

      expect(mockPrisma.auditLog.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({
            action: 'ORDER_STATUS_UPDATED',
            orderId: testOrderId,
          }),
        }),
      );
    });
  });

  describe('calculateMonthlyRevenue', () => {
    it('should calculate revenue for shipped and delivered orders only', async () => {
      const month = new Date('2026-02-01');
      mockPrisma.lineItem.findMany.mockResolvedValue([
        {
          quantity: 2,
          unitPrice: 50,
          order: { currency: 'USD' },
        },
        {
          quantity: 1,
          unitPrice: 100,
          order: { currency: 'USD' },
        },
      ]);

      const result = await service.calculateMonthlyRevenue(month, testOrgId);

      expect(result).toEqual([{ currency: 'USD', total: 200 }]);
    });

    it('should aggregate by currency', async () => {
      const month = new Date('2026-02-01');
      mockPrisma.lineItem.findMany.mockResolvedValue([
        { quantity: 1, unitPrice: 100, order: { currency: 'USD' } },
        { quantity: 1, unitPrice: 100, order: { currency: 'EUR' } },
      ]);

      const result = await service.calculateMonthlyRevenue(month, testOrgId);

      expect(result).toContainEqual({ currency: 'USD', total: 100 });
      expect(result).toContainEqual({ currency: 'EUR', total: 100 });
    });

    it('should use UTC date boundaries', async () => {
      const month = new Date('2026-02-15');
      mockPrisma.lineItem.findMany.mockResolvedValue([]);

      await service.calculateMonthlyRevenue(month, testOrgId);

      const callArgs = mockPrisma.lineItem.findMany.mock.calls[0][0];
      const dateRange = callArgs.where.order.createdAt;

      // Verify exact UTC boundaries for February 2026
      expect(dateRange.gte).toEqual(new Date('2026-02-01T00:00:00.000Z'));
      expect(dateRange.lte.getUTCFullYear()).toBe(2026);
      expect(dateRange.lte.getUTCMonth()).toBe(1); // February is month 1
      expect(dateRange.lte.getUTCDate()).toBe(28); // Feb 2026 has 28 days
    });
  });

  describe('bulkUpdateStatus', () => {
    it('should update multiple orders with valid transitions', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst
        .mockResolvedValueOnce({ id: 'ord1', status: 'pending' })
        .mockResolvedValueOnce({ id: 'ord2', status: 'pending' });
      mockPrisma.order.updateMany.mockResolvedValue({ count: 1 });
      mockPrisma.order.findUnique.mockResolvedValue({ status: 'confirmed' });
      mockRedis.keys.mockResolvedValue([]);

      const updated = await service.bulkUpdateStatus(
        ['ord1', 'ord2'],
        'confirmed',
        testOrgId,
      );

      expect(updated).toBe(2);
    });

    it('should skip invalid transitions silently', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst
        .mockResolvedValueOnce({ id: 'ord1', status: 'delivered' })
        .mockResolvedValueOnce({ id: 'ord2', status: 'pending' });
      mockPrisma.order.updateMany.mockResolvedValue({ count: 1 });
      mockPrisma.order.findUnique.mockResolvedValue({ status: 'confirmed' });
      mockRedis.keys.mockResolvedValue([]);

      const updated = await service.bulkUpdateStatus(
        ['ord1', 'ord2'],
        'confirmed',
        testOrgId,
      );

      // Only ord2 should succeed
      expect(updated).toBe(1);
    });

    it('should rethrow infrastructure errors', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findFirst.mockRejectedValueOnce(
        new Error('Database connection failed'),
      );

      await expect(
        service.bulkUpdateStatus(['ord1'], 'confirmed', testOrgId),
      ).rejects.toThrow('Database connection failed');
    });
  });

  describe('getOrdersForExport', () => {
    it('should return full order data with line items and customer', async () => {
      const orders = [
        {
          id: 'ord1',
          lineItems: [],
          customer: { id: 'cust1' },
          payments: [],
        },
      ];
      mockPrisma.order.findMany.mockResolvedValue(orders);

      const result = await service.getOrdersForExport({}, testOrgId);

      expect(result).toEqual(orders);
      expect(mockPrisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          include: expect.objectContaining({
            lineItems: true,
            customer: true,
            payments: true,
          }),
        }),
      );
    });

    it('should respect maxRows boundary', async () => {
      mockPrisma.order.findMany.mockResolvedValue([]);

      await service.getOrdersForExport({}, testOrgId);

      expect(mockPrisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          take: 10000,
        }),
      );
    });

    it('should apply status filter', async () => {
      mockPrisma.order.findMany.mockResolvedValue([]);

      await service.getOrdersForExport({ status: 'shipped' }, testOrgId);

      expect(mockPrisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            status: 'shipped',
          }),
        }),
      );
    });
  });
});

import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException, ConflictException } from '@nestjs/common';
import { OrderService } from './OrderService';

describe('OrderService', () => {
  let service: OrderService;
  let prismaService: any;
  let redisService: any;
  let emailService: any;
  let paymentGateway: any;

  const mockOrder = {
    id: 'order-123',
    organizationId: 'org-1',
    customerId: 'cust-1',
    status: 'pending' as const,
    currency: 'USD',
    totalAmount: 100,
    createdAt: new Date('2026-04-01'),
  };

  const mockLineItem = {
    productId: 'prod-1',
    quantity: 2,
    unitPrice: 50,
  };

  beforeEach(async () => {
    prismaService = {
      order: {
        findMany: jest.fn(),
        findFirst: jest.fn(),
        create: jest.fn(),
        delete: jest.fn(),
        update: jest.fn(),
        updateMany: jest.fn(),
      },
      lineItem: {
        deleteMany: jest.fn(),
      },
      $transaction: jest.fn(),
    };

    redisService = {
      get: jest.fn(),
      set: jest.fn(),
      deletePattern: jest.fn(),
    };

    emailService = {
      sendOrderShipped: jest.fn(),
    };

    paymentGateway = {
      charge: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        OrderService,
        { provide: 'PrismaService', useValue: prismaService },
        { provide: 'RedisService', useValue: redisService },
        { provide: 'EmailService', useValue: emailService },
        { provide: 'PaymentGateway', useValue: paymentGateway },
      ],
    }).compile();

    service = module.get<OrderService>(OrderService);
    jest.clearAllMocks();
  });

  describe('findAll', () => {
    it('returns orders from database when cache miss', async () => {
      redisService.get.mockResolvedValue(null);
      prismaService.order.findMany.mockResolvedValue([mockOrder]);

      const result = await service.findAll(
        { status: 'pending' },
        'org-1',
      );

      expect(result).toEqual([mockOrder]);
      expect(prismaService.order.findMany).toHaveBeenCalled();
      expect(redisService.set).toHaveBeenCalled();
    });

    it('returns cached orders and revives Date objects', async () => {
      const cached = JSON.stringify([{ ...mockOrder, createdAt: '2026-04-01T00:00:00.000Z' }]);
      redisService.get.mockResolvedValue(cached);

      const result = await service.findAll({}, 'org-1');

      expect(result[0].createdAt instanceof Date).toBe(true);
      expect(prismaService.order.findMany).not.toHaveBeenCalled();
    });

    it('respects take/skip pagination with max bounds', async () => {
      redisService.get.mockResolvedValue(null);
      prismaService.order.findMany.mockResolvedValue([]);

      await service.findAll({ take: 999, skip: 10 }, 'org-1');

      expect(prismaService.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({ take: 100 }),
      );
    });

    it('enforces organization scope in query', async () => {
      redisService.get.mockResolvedValue(null);
      prismaService.order.findMany.mockResolvedValue([]);

      await service.findAll({}, 'org-2');

      expect(prismaService.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ organizationId: 'org-2' }),
        }),
      );
    });
  });

  describe('findById', () => {
    it('returns order when found', async () => {
      prismaService.order.findFirst.mockResolvedValue(mockOrder);

      const result = await service.findById('order-123', 'org-1');

      expect(result).toEqual(mockOrder);
      expect(prismaService.order.findFirst).toHaveBeenCalledWith({
        where: { id: 'order-123', organizationId: 'org-1' },
      });
    });

    it('throws NotFoundException when order not found', async () => {
      prismaService.order.findFirst.mockResolvedValue(null);

      await expect(
        service.findById('order-999', 'org-1'),
      ).rejects.toThrow(NotFoundException);
    });

    it('enforces organization boundary', async () => {
      prismaService.order.findFirst.mockResolvedValue(null);

      await expect(
        service.findById('order-123', 'org-2'),
      ).rejects.toThrow(NotFoundException);
    });
  });

  describe('create', () => {
    it('creates order with valid line items', async () => {
      const createdOrder = { ...mockOrder };
      prismaService.$transaction.mockImplementation(async (fn) => {
        return await fn(prismaService);
      });
      prismaService.order.create.mockResolvedValue(createdOrder);

      const result = await service.create(
        {
          customerId: 'cust-1',
          lineItems: [mockLineItem],
          currency: 'USD',
        },
        'org-1',
      );

      expect(result).toEqual(createdOrder);
      expect(redisService.deletePattern).toHaveBeenCalledWith('orders:org-1:*');
    });

    it('validates positive quantity', async () => {
      await expect(
        service.create(
          {
            customerId: 'cust-1',
            lineItems: [{ ...mockLineItem, quantity: -5 }],
            currency: 'USD',
          },
          'org-1',
        ),
      ).rejects.toThrow('Invalid quantity: -5');
    });

    it('rejects zero quantity', async () => {
      await expect(
        service.create(
          {
            customerId: 'cust-1',
            lineItems: [{ ...mockLineItem, quantity: 0 }],
            currency: 'USD',
          },
          'org-1',
        ),
      ).rejects.toThrow('Invalid quantity: 0');
    });

    it('validates positive price', async () => {
      await expect(
        service.create(
          {
            customerId: 'cust-1',
            lineItems: [{ ...mockLineItem, unitPrice: -10 }],
            currency: 'USD',
          },
          'org-1',
        ),
      ).rejects.toThrow('Invalid unitPrice: -10');
    });

    it('rejects NaN or Infinity values', async () => {
      await expect(
        service.create(
          {
            customerId: 'cust-1',
            lineItems: [{ ...mockLineItem, quantity: NaN }],
            currency: 'USD',
          },
          'org-1',
        ),
      ).rejects.toThrow('Invalid quantity');
    });
  });

  describe('deleteOrder', () => {
    it('deletes order and line items with correct IDs', async () => {
      prismaService.order.findFirst.mockResolvedValue(mockOrder);
      prismaService.$transaction.mockImplementation(async (fn) => {
        return await fn(prismaService);
      });

      await service.deleteOrder('order-123', 'org-1');

      expect(prismaService.lineItem.deleteMany).toHaveBeenCalledWith({
        where: { orderId: 'order-123' },
      });
      expect(prismaService.order.delete).toHaveBeenCalledWith({
        where: { id: 'order-123' },
      });
    });

    it('throws NotFoundException for non-existent order', async () => {
      prismaService.order.findFirst.mockResolvedValue(null);

      await expect(
        service.deleteOrder('order-999', 'org-1'),
      ).rejects.toThrow(NotFoundException);
    });

    it('invalidates cache after deletion', async () => {
      prismaService.order.findFirst.mockResolvedValue(mockOrder);
      prismaService.$transaction.mockImplementation(async (fn) => {
        return await fn(prismaService);
      });

      await service.deleteOrder('order-123', 'org-1');

      expect(redisService.deletePattern).toHaveBeenCalledWith('orders:org-1:*');
    });
  });

  describe('updateStatus', () => {
    it('transitions pending to confirmed with TOCTOU protection', async () => {
      prismaService.order.findFirst.mockResolvedValue(mockOrder);
      prismaService.order.updateMany.mockResolvedValue({ count: 1 });

      await service.updateStatus('order-123', 'confirmed', 'org-1');

      expect(prismaService.order.updateMany).toHaveBeenCalledWith({
        where: { id: 'order-123', status: 'pending' },
        data: { status: 'confirmed' },
      });
    });

    it('throws specific error for invalid state transition', async () => {
      prismaService.order.findFirst.mockResolvedValue({
        ...mockOrder,
        status: 'delivered',
      });

      await expect(
        service.updateStatus('order-123', 'confirmed', 'org-1'),
      ).rejects.toThrow('Cannot transition from delivered to confirmed');
    });

    it('detects concurrent status changes via conditional update', async () => {
      prismaService.order.findFirst.mockResolvedValue(mockOrder);
      prismaService.order.updateMany.mockResolvedValue({ count: 0 });

      await expect(
        service.updateStatus('order-123', 'confirmed', 'org-1'),
      ).rejects.toThrow(ConflictException);
    });

    it('sends email notification on shipped status', async () => {
      prismaService.order.findFirst.mockResolvedValue({
        ...mockOrder,
        status: 'processing',
      });
      prismaService.order.updateMany.mockResolvedValue({ count: 1 });

      await service.updateStatus('order-123', 'shipped', 'org-1');

      expect(emailService.sendOrderShipped).toHaveBeenCalledWith('cust-1', 'order-123');
    });

    it('handles email send errors gracefully without blocking status update', async () => {
      prismaService.order.findFirst.mockResolvedValue({
        ...mockOrder,
        status: 'processing',
      });
      prismaService.order.updateMany.mockResolvedValue({ count: 1 });
      emailService.sendOrderShipped.mockRejectedValue(new Error('Email failed'));

      await expect(
        service.updateStatus('order-123', 'shipped', 'org-1'),
      ).resolves.toBeDefined();

      expect(emailService.sendOrderShipped).toHaveBeenCalled();
    });
  });

  describe('calculateMonthlyRevenue', () => {
    it('aggregates revenue by currency for the month', async () => {
      prismaService.order.findMany.mockResolvedValue([
        { ...mockOrder, currency: 'USD', totalAmount: 100 },
        { ...mockOrder, currency: 'USD', totalAmount: 50 },
        { ...mockOrder, currency: 'EUR', totalAmount: 80 },
      ]);

      const result = await service.calculateMonthlyRevenue(
        new Date('2026-04-15'),
        'org-1',
      );

      expect(result.some(r => r.currency === 'USD' && r.total === 150)).toBe(true);
      expect(result.some(r => r.currency === 'EUR' && r.total === 80)).toBe(true);
    });

    it('uses UTC month boundaries excluding partial last day', async () => {
      prismaService.order.findMany.mockResolvedValue([]);

      await service.calculateMonthlyRevenue(new Date('2026-04-15'), 'org-1');

      const callArgs = prismaService.order.findMany.mock.calls[0][0];
      const gte = callArgs.where.createdAt.gte;
      const lt = callArgs.where.createdAt.lt;

      expect(gte.getUTCFullYear()).toBe(2026);
      expect(gte.getUTCMonth()).toBe(3); // April
      expect(gte.getUTCDate()).toBe(1);
      expect(lt.getUTCFullYear()).toBe(2026);
      expect(lt.getUTCMonth()).toBe(4); // May
      expect(lt.getUTCDate()).toBe(1);
    });
  });

  describe('bulkUpdateStatus', () => {
    it('updates only orders with valid transitions', async () => {
      prismaService.order.findFirst
        .mockResolvedValueOnce({ ...mockOrder, status: 'pending' })
        .mockResolvedValueOnce({ ...mockOrder, status: 'delivered' });
      prismaService.order.updateMany
        .mockResolvedValueOnce({ count: 1 })
        .mockResolvedValueOnce({ count: 0 });

      const updated = await service.bulkUpdateStatus(
        ['order-1', 'order-2'],
        'confirmed',
        'org-1',
      );

      expect(updated).toBe(1);
      expect(prismaService.order.updateMany).toHaveBeenCalledTimes(2);
    });

    it('returns count of updated orders with specific arguments', async () => {
      prismaService.order.findFirst.mockResolvedValue({
        ...mockOrder,
        status: 'pending',
      });
      prismaService.order.updateMany.mockResolvedValue({ count: 1 });

      const updated = await service.bulkUpdateStatus(
        ['order-1', 'order-2'],
        'confirmed',
        'org-1',
      );

      expect(updated).toBe(2);
      expect(prismaService.order.updateMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            status: 'pending',
          }),
        }),
      );
    });

    it('invalidates cache after bulk update', async () => {
      prismaService.order.findFirst.mockResolvedValue(mockOrder);
      prismaService.order.updateMany.mockResolvedValue({ count: 1 });

      await service.bulkUpdateStatus(['order-1'], 'confirmed', 'org-1');

      expect(redisService.deletePattern).toHaveBeenCalledWith('orders:org-1:*');
    });
  });

  describe('getOrdersForExport', () => {
    it('exports orders with full relationships', async () => {
      const exportOrder = {
        ...mockOrder,
        lineItems: [mockLineItem],
        customer: { id: 'cust-1', name: 'John' },
        payments: [],
      };
      prismaService.order.findMany.mockResolvedValue([exportOrder]);

      const result = await service.getOrdersForExport({}, 'org-1');

      expect(result).toEqual([exportOrder]);
      expect(prismaService.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          take: 10000,
          include: expect.objectContaining({
            lineItems: true,
            customer: true,
            payments: true,
          }),
        }),
      );
    });

    it('enforces organization scope in export', async () => {
      prismaService.order.findMany.mockResolvedValue([]);

      await service.getOrdersForExport({}, 'org-2');

      expect(prismaService.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            organizationId: 'org-2',
          }),
        }),
      );
    });
  });
});

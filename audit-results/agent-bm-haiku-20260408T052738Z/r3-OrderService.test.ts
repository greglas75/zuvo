// FILE: OrderService.test.ts

import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { OrderService } from './r2-OrderService';

const mockOrgId = 'org-123';
const mockOrderId = 'order-456';
const mockCustomerId = 'customer-789';
const mockCustomerEmail = 'customer@example.com';

const mockCustomer = {
  id: mockCustomerId,
  email: mockCustomerEmail,
};

const mockLineItems = [
  { productId: 'prod-1', quantity: 2, unitPrice: 50 },
  { productId: 'prod-2', quantity: 1, unitPrice: 100 },
];

const mockOrder = {
  id: mockOrderId,
  organizationId: mockOrgId,
  customerId: mockCustomerId,
  customer: mockCustomer,
  currency: 'USD',
  status: 'pending',
  total: 200,
  createdAt: new Date('2026-04-01'),
  updatedAt: new Date('2026-04-01'),
  lineItems: mockLineItems,
};

describe('OrderService', () => {
  let service: OrderService;
  let mockPrisma: any;
  let mockRedis: any;
  let mockEmail: any;
  let mockPayment: any;

  beforeEach(async () => {
    mockPrisma = {
      order: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
        delete: jest.fn(),
      },
      lineItem: {
        deleteMany: jest.fn(),
      },
      $transaction: jest.fn((cb) => cb(mockPrisma)),
    };

    mockRedis = {
      get: jest.fn().mockResolvedValue(null),
      set: jest.fn().mockResolvedValue(undefined),
      scan: jest.fn().mockResolvedValue([]),
      del: jest.fn().mockResolvedValue(undefined),
    };

    mockEmail = {
      sendEmail: jest.fn().mockResolvedValue(undefined),
    };

    mockPayment = {
      processPayment: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
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
    it('returns cached orders on cache hit', async () => {
      const cachedOrders = [mockOrder];
      mockRedis.get.mockResolvedValueOnce(JSON.stringify(cachedOrders));

      const result = await service.findAll({}, mockOrgId);

      expect(result).toEqual(cachedOrders);
      expect(mockPrisma.order.findMany).not.toHaveBeenCalled();
    });

    it('queries database on cache miss and caches result', async () => {
      mockPrisma.order.findMany.mockResolvedValueOnce([mockOrder]);

      const result = await service.findAll({}, mockOrgId);

      expect(mockPrisma.order.findMany).toHaveBeenCalledWith({
        where: { organizationId: mockOrgId },
        take: 10,
        skip: 0,
        include: { lineItems: true },
      });
      expect(mockRedis.set).toHaveBeenCalled();
    });

    it('applies status filter', async () => {
      mockPrisma.order.findMany.mockResolvedValueOnce([]);

      await service.findAll({ status: 'shipped' }, mockOrgId);

      expect(mockPrisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ status: 'shipped' }),
        }),
      );
    });
  });

  describe('findById', () => {
    it('returns order when found in correct org', async () => {
      mockPrisma.order.findUnique.mockResolvedValueOnce(mockOrder);

      const result = await service.findById(mockOrderId, mockOrgId);

      expect(result).toEqual(mockOrder);
    });

    it('throws NotFoundException when order not found', async () => {
      mockPrisma.order.findUnique.mockResolvedValueOnce(null);

      await expect(service.findById(mockOrderId, mockOrgId)).rejects.toThrow(NotFoundException);
    });

    it('throws NotFoundException when order belongs to different org', async () => {
      mockPrisma.order.findUnique.mockResolvedValueOnce({
        ...mockOrder,
        organizationId: 'other-org',
      });

      await expect(service.findById(mockOrderId, mockOrgId)).rejects.toThrow(NotFoundException);
    });
  });

  describe('create', () => {
    it('creates order with line items in transaction', async () => {
      const dto = {
        customerId: mockCustomerId,
        lineItems: mockLineItems,
        currency: 'USD',
      };

      mockPrisma.$transaction.mockImplementationOnce(async (cb) => {
        return cb(mockPrisma);
      });

      mockPrisma.order.create = jest.fn().mockResolvedValueOnce(mockOrder);

      await service.create(dto, mockOrgId);

      expect(mockPrisma.$transaction).toHaveBeenCalled();
      expect(mockRedis.del).toHaveBeenCalled();
    });

    it('throws error when line items are empty', async () => {
      const dto = {
        customerId: mockCustomerId,
        lineItems: [],
        currency: 'USD',
      };

      await expect(service.create(dto, mockOrgId)).rejects.toThrow('Invalid order data');
    });
  });

  describe('updateStatus', () => {
    it('transitions pending to confirmed', async () => {
      mockPrisma.order.findUnique.mockResolvedValueOnce(mockOrder);
      mockPrisma.order.update.mockResolvedValueOnce({
        ...mockOrder,
        status: 'confirmed',
      });

      await service.updateStatus(mockOrderId, 'confirmed', mockOrgId);

      expect(mockPrisma.order.update).toHaveBeenCalledWith({
        where: { id: mockOrderId, status: 'pending' },
        data: { status: 'confirmed' },
      });
    });

    it('throws error on invalid transition', async () => {
      mockPrisma.order.findUnique.mockResolvedValueOnce({
        ...mockOrder,
        status: 'delivered',
      });

      await expect(service.updateStatus(mockOrderId, 'pending', mockOrgId)).rejects.toThrow(
        'Invalid status transition',
      );
    });

    it('sends email notification when transitioning to shipped', async () => {
      mockPrisma.order.findUnique.mockResolvedValueOnce({
        ...mockOrder,
        status: 'processing',
        customer: mockCustomer,
      });
      mockPrisma.order.update.mockResolvedValueOnce({
        ...mockOrder,
        status: 'shipped',
      });

      await service.updateStatus(mockOrderId, 'shipped', mockOrgId);

      expect(mockEmail.sendEmail).toHaveBeenCalledWith(
        mockCustomerEmail,
        expect.stringContaining('Shipped'),
        expect.any(String),
      );
    });

    it('handles email send failure gracefully', async () => {
      mockPrisma.order.findUnique.mockResolvedValueOnce({
        ...mockOrder,
        status: 'processing',
        customer: mockCustomer,
      });
      mockPrisma.order.update.mockResolvedValueOnce({
        ...mockOrder,
        status: 'shipped',
      });
      mockEmail.sendEmail.mockRejectedValueOnce(new Error('Email service down'));

      const result = await service.updateStatus(mockOrderId, 'shipped', mockOrgId);

      expect(result.status).toBe('shipped');
      expect(mockEmail.sendEmail).toHaveBeenCalled();
    });
  });

  describe('deleteOrder', () => {
    it('deletes order and line items in transaction', async () => {
      mockPrisma.order.findUnique.mockResolvedValueOnce(mockOrder);
      mockPrisma.$transaction.mockImplementationOnce(async (cb) => cb(mockPrisma));

      await service.deleteOrder(mockOrderId, mockOrgId);

      expect(mockPrisma.lineItem.deleteMany).toHaveBeenCalledWith({
        where: { orderId: mockOrderId },
      });
      expect(mockPrisma.order.delete).toHaveBeenCalledWith({
        where: { id: mockOrderId },
      });
    });

    it('throws NotFoundException when order not found', async () => {
      mockPrisma.order.findUnique.mockResolvedValueOnce(null);

      await expect(service.deleteOrder(mockOrderId, mockOrgId)).rejects.toThrow(NotFoundException);
    });
  });

  describe('calculateMonthlyRevenue', () => {
    it('aggregates revenue by currency for the month', async () => {
      const month = new Date('2026-04-01');
      const order1 = { ...mockOrder, currency: 'USD', total: 100 };
      const order2 = { ...mockOrder, currency: 'USD', total: 200 };
      const order3 = { ...mockOrder, currency: 'EUR', total: 150 };

      mockPrisma.order.findMany.mockResolvedValueOnce([order1, order2, order3]);

      const result = await service.calculateMonthlyRevenue(month, mockOrgId);

      expect(result).toEqual([
        { currency: 'USD', total: 300 },
        { currency: 'EUR', total: 150 },
      ]);
    });

    it('uses correct month boundary (inclusive start, exclusive end)', async () => {
      const month = new Date('2026-04-01');
      mockPrisma.order.findMany.mockResolvedValueOnce([]);

      await service.calculateMonthlyRevenue(month, mockOrgId);

      const call = mockPrisma.order.findMany.mock.calls[0][0];
      expect(call.where.createdAt.gte).toEqual(new Date('2026-04-01'));
      expect(call.where.createdAt.lt).toEqual(new Date('2026-05-01'));
    });
  });

  describe('bulkUpdateStatus', () => {
    it('updates valid transitions and tracks failures', async () => {
      const ids = ['order-1', 'order-2', 'order-3'];
      mockPrisma.order.findUnique
        .mockResolvedValueOnce({ ...mockOrder, id: 'order-1', status: 'pending' })
        .mockResolvedValueOnce({ ...mockOrder, id: 'order-2', status: 'shipped' })
        .mockResolvedValueOnce({ ...mockOrder, id: 'order-3', status: 'pending' });

      mockPrisma.order.update
        .mockResolvedValueOnce({ status: 'confirmed' })
        .mockResolvedValueOnce({ status: 'confirmed' });

      const updated = await service.bulkUpdateStatus(ids, 'confirmed', mockOrgId);

      expect(updated).toBe(2);
    });

    it('skips invalid transitions without throwing', async () => {
      const ids = ['order-1', 'order-2'];
      mockPrisma.order.findUnique
        .mockResolvedValueOnce({ ...mockOrder, id: 'order-1', status: 'pending' })
        .mockResolvedValueOnce({ ...mockOrder, id: 'order-2', status: 'delivered' });

      mockPrisma.order.update.mockResolvedValueOnce({ status: 'confirmed' });

      const updated = await service.bulkUpdateStatus(ids, 'confirmed', mockOrgId);

      expect(updated).toBe(1);
    });

    it('handles database errors gracefully', async () => {
      const ids = ['order-1'];
      mockPrisma.order.findUnique.mockRejectedValueOnce(new Error('DB connection lost'));

      const updated = await service.bulkUpdateStatus(ids, 'confirmed', mockOrgId);

      expect(updated).toBe(0);
    });
  });

  describe('getOrdersForExport', () => {
    it('returns full order data including relations up to maxRows', async () => {
      mockPrisma.order.findMany.mockResolvedValueOnce([mockOrder]);

      await service.getOrdersForExport({}, mockOrgId);

      expect(mockPrisma.order.findMany).toHaveBeenCalledWith({
        where: { organizationId: mockOrgId },
        take: 10000,
        include: {
          lineItems: true,
          customer: true,
          payments: true,
        },
      });
    });

    it('respects maxRows boundary at 10000', async () => {
      mockPrisma.order.findMany.mockResolvedValueOnce([]);

      await service.getOrdersForExport({}, mockOrgId);

      expect(mockPrisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          take: 10000,
        }),
      );
    });
  });
});

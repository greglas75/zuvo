import { OrderService } from './r2-OrderService';
import { NotFoundException, BadRequestException, ConflictException } from '@nestjs/common';

describe('OrderService', () => {
  let service: OrderService;
  let prismaMock: any;
  let redisMock: any;
  let emailServiceMock: any;
  let paymentGatewayMock: any;

  const ORG_ID = 'test-org-id';
  const CUSTOMER_ID = 'cust-123';
  const ORDER_ID = 'order-123';

  beforeEach(() => {
    prismaMock = {
      order: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        delete: jest.fn(),
        updateMany: jest.fn(),
        groupBy: jest.fn(),
      },
      lineItem: {
        deleteMany: jest.fn(),
      },
      auditLog: {
        create: jest.fn(),
      },
      $transaction: jest.fn((callback) => callback(prismaMock)),
    };

    redisMock = {
      get: jest.fn(),
      set: jest.fn(),
      incr: jest.fn(),
    };

    emailServiceMock = {
      sendShippingNotification: jest.fn().mockImplementation(() => Promise.resolve()),
    };

    paymentGatewayMock = {};

    service = new OrderService(prismaMock, redisMock, emailServiceMock, paymentGatewayMock);
    jest.clearAllMocks();
  });

  describe('findAll', () => {
    it('returns orders from cache if hit', async () => {
      const mockCachedOrders = [{ id: '1', createdAt: new Date().toISOString() }];
      redisMock.get.mockResolvedValueOnce(JSON.stringify(mockCachedOrders));
      
      const res = await service.findAll({}, ORG_ID);
      
      expect(res).toBeDefined();
      expect(res[0].id).toBe('1');
      expect(res[0].createdAt).toBeInstanceOf(Date);
      expect(prismaMock.order.findMany).not.toHaveBeenCalled();
    });

    it('returns orders from db if cache miss and caches them', async () => {
      redisMock.get.mockResolvedValueOnce(null);
      const mockOrders = [{ id: '1' }];
      prismaMock.order.findMany.mockResolvedValueOnce(mockOrders);

      const res = await service.findAll({ status: 'pending', customerId: CUSTOMER_ID, take: 10, skip: 0 }, ORG_ID);

      expect(res).toEqual(mockOrders);
      expect(prismaMock.order.findMany).toHaveBeenCalledWith({
        where: { orgId: ORG_ID, status: 'pending', customerId: CUSTOMER_ID },
        take: 10,
        skip: 0
      });
      expect(redisMock.set).toHaveBeenCalledTimes(1);
    });

    it('throws BadRequestException for invalid take', async () => {
      await expect(service.findAll({ take: -5 }, ORG_ID)).rejects.toThrow(BadRequestException);
      await expect(service.findAll({ take: -5 }, ORG_ID)).rejects.toThrow('Invalid take');
    });

    it('throws BadRequestException for invalid skip', async () => {
      await expect(service.findAll({ skip: -1 }, ORG_ID)).rejects.toThrow(BadRequestException);
      await expect(service.findAll({ skip: -1 }, ORG_ID)).rejects.toThrow('Invalid skip');
    });
  });

  describe('findById', () => {
    it('returns order from cache if hit', async () => {
      const mockOrder = { id: ORDER_ID, orgId: ORG_ID };
      redisMock.get.mockResolvedValueOnce(JSON.stringify(mockOrder));

      const res = await service.findById(ORDER_ID, ORG_ID);
      expect(res.id).toBe(ORDER_ID);
      expect(prismaMock.order.findUnique).not.toHaveBeenCalled();
    });

    it('returns order from db if cache miss and caches it', async () => {
      redisMock.get.mockResolvedValueOnce(null);
      const mockOrder = { id: ORDER_ID, orgId: ORG_ID };
      prismaMock.order.findUnique.mockResolvedValueOnce(mockOrder);

      const res = await service.findById(ORDER_ID, ORG_ID);
      expect(res).toEqual(mockOrder);
      expect(prismaMock.order.findUnique).toHaveBeenCalledWith({ where: { id: ORDER_ID } });
      expect(redisMock.set).toHaveBeenCalledTimes(1);
    });

    it('throws NotFoundException if not found', async () => {
      redisMock.get.mockResolvedValueOnce(null);
      prismaMock.order.findUnique.mockResolvedValueOnce(null);
      await expect(service.findById(ORDER_ID, ORG_ID)).rejects.toThrow(NotFoundException);
      await expect(service.findById(ORDER_ID, ORG_ID)).rejects.toThrow(`Order ${ORDER_ID} not found`);
    });

    it('throws NotFoundException if orgId mismatches', async () => {
      redisMock.get.mockResolvedValueOnce(null);
      prismaMock.order.findUnique.mockResolvedValueOnce({ id: ORDER_ID, orgId: 'OTHER_ORG' });
      await expect(service.findById(ORDER_ID, ORG_ID)).rejects.toThrow(NotFoundException);
      await expect(service.findById(ORDER_ID, ORG_ID)).rejects.toThrow(`Order ${ORDER_ID} not found`);
    });

    it('handles malformed cache payload by returning from db', async () => {
        redisMock.get.mockRejectedValueOnce(new Error('Redis failure'));
        const mockOrder = { id: ORDER_ID, orgId: ORG_ID };
        prismaMock.order.findUnique.mockResolvedValueOnce(mockOrder);

        const res = await service.findById(ORDER_ID, ORG_ID);
        expect(res).toEqual(mockOrder);
    });
  });

  describe('create', () => {
    const validDto = {
      customerId: CUSTOMER_ID,
      currency: 'USD',
      lineItems: [{ productId: 'p1', quantity: 1, unitPrice: 100 }]
    };

    it('creates an order, audits, increments redis', async () => {
      const createdOrder = { id: ORDER_ID, orgId: ORG_ID, status: 'pending' };
      prismaMock.order.create.mockResolvedValueOnce(createdOrder);

      const res = await service.create(validDto, ORG_ID);

      expect(res).toEqual(createdOrder);
      expect(prismaMock.order.create).toHaveBeenCalledWith({
        data: {
          orgId: ORG_ID,
          customerId: CUSTOMER_ID,
          currency: 'USD',
          status: 'pending',
          lineItems: { create: validDto.lineItems }
        },
        include: { lineItems: true }
      });
      expect(prismaMock.auditLog.create).toHaveBeenCalledWith({
        data: { orgId: ORG_ID, orderId: ORDER_ID, action: 'CREATE_ORDER' }
      });
      expect(redisMock.incr).toHaveBeenCalledWith(`org:${ORG_ID}:orders:v1`);
    });

    it('throws BadRequestException for missing customerId', async () => {
      const dto = { ...validDto, customerId: '' };
      await expect(service.create(dto, ORG_ID)).rejects.toThrow(BadRequestException);
      await expect(service.create(dto, ORG_ID)).rejects.toThrow('Invalid customerId');
    });

    it('throws BadRequestException for invalid currency', async () => {
      const dto = { ...validDto, currency: 'US' };
      await expect(service.create(dto, ORG_ID)).rejects.toThrow(BadRequestException);
      await expect(service.create(dto, ORG_ID)).rejects.toThrow('Invalid currency');
    });

    it('throws BadRequestException for invalid quantity', async () => {
      const dto = { ...validDto, lineItems: [{ productId: 'p1', quantity: -1, unitPrice: 100 }] };
      await expect(service.create(dto, ORG_ID)).rejects.toThrow(BadRequestException);
      await expect(service.create(dto, ORG_ID)).rejects.toThrow('Invalid quantity');
    });

    it('rolls back transaction if create fails', async () => {
       prismaMock.order.create.mockRejectedValueOnce(new Error('DB Error'));
       await expect(service.create(validDto, ORG_ID)).rejects.toThrow('DB Error');
       expect(prismaMock.auditLog.create).not.toHaveBeenCalled();
    });
  });

  describe('deleteOrder', () => {
    it('deletes line items, order, audits, increments redis', async () => {
      prismaMock.order.findUnique.mockResolvedValueOnce({ id: ORDER_ID, orgId: ORG_ID });

      await service.deleteOrder(ORDER_ID, ORG_ID);

      expect(prismaMock.lineItem.deleteMany).toHaveBeenCalledWith({ where: { orderId: ORDER_ID } });
      expect(prismaMock.order.delete).toHaveBeenCalledWith({ where: { id: ORDER_ID } });
      expect(prismaMock.auditLog.create).toHaveBeenCalledWith({
        data: { orgId: ORG_ID, orderId: ORDER_ID, action: 'DELETE_ORDER' }
      });
      expect(redisMock.incr).toHaveBeenCalledWith(`org:${ORG_ID}:orders:v1`);
    });

    it('throws NotFoundException if not found', async () => {
      prismaMock.order.findUnique.mockResolvedValueOnce(null);
      await expect(service.deleteOrder(ORDER_ID, ORG_ID)).rejects.toThrow(NotFoundException);
      await expect(service.deleteOrder(ORDER_ID, ORG_ID)).rejects.toThrow(`Order ${ORDER_ID} not found`);
    });
  });

  describe('updateStatus', () => {
    it('updates status appropriately and sends email if shipped', async () => {
      prismaMock.order.findUnique.mockResolvedValue({ id: ORDER_ID, orgId: ORG_ID, status: 'processing', customerId: CUSTOMER_ID });
      prismaMock.order.updateMany.mockResolvedValueOnce({ count: 1 });

      const res = await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);

      expect(prismaMock.order.updateMany).toHaveBeenCalledWith({
        where: { id: ORDER_ID, status: 'processing', orgId: ORG_ID },
        data: { status: 'shipped' }
      });
      expect(prismaMock.auditLog.create).toHaveBeenCalledWith({
        data: { orgId: ORG_ID, orderId: ORDER_ID, action: 'UPDATE_STATUS_shipped' }
      });
      expect(emailServiceMock.sendShippingNotification).toHaveBeenCalledWith(CUSTOMER_ID, ORDER_ID);
      expect(redisMock.incr).toHaveBeenCalledWith(`org:${ORG_ID}:orders:v1`);
    });

    it('returns early if status is the same', async () => {
       const order = { id: ORDER_ID, orgId: ORG_ID, status: 'pending' };
       prismaMock.order.findUnique.mockResolvedValue(order);

       const res = await service.updateStatus(ORDER_ID, 'pending', ORG_ID);
       expect(res).toEqual(order);
       expect(prismaMock.order.updateMany).not.toHaveBeenCalled();
    });

    it('throws ConflictException for invalid transition', async () => {
      prismaMock.order.findUnique.mockResolvedValue({ id: ORDER_ID, orgId: ORG_ID, status: 'pending' });
      await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_ID)).rejects.toThrow(ConflictException);
      await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_ID)).rejects.toThrow('Cannot transition from pending to shipped');
    });

    it('throws ConflictException for TOCTOU concurrent modification', async () => {
      prismaMock.order.findUnique.mockResolvedValue({ id: ORDER_ID, orgId: ORG_ID, status: 'pending' });
      prismaMock.order.updateMany.mockResolvedValueOnce({ count: 0 });

      await expect(service.updateStatus(ORDER_ID, 'confirmed', ORG_ID)).rejects.toThrow(ConflictException);
      await expect(service.updateStatus(ORDER_ID, 'confirmed', ORG_ID)).rejects.toThrow('Order state changed concurrently');
    });

    it('handles email rejection without crashing', async () => {
      prismaMock.order.findUnique.mockResolvedValue({ id: ORDER_ID, orgId: ORG_ID, status: 'processing', customerId: CUSTOMER_ID });
      prismaMock.order.updateMany.mockResolvedValueOnce({ count: 1 });
      emailServiceMock.sendShippingNotification.mockRejectedValueOnce(new Error('Email provider down'));

      await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);
      expect(redisMock.incr).toHaveBeenCalled();
    });
  });

  describe('calculateMonthlyRevenue', () => {
    it('aggregates correctly', async () => {
      prismaMock.order.groupBy.mockResolvedValueOnce([
        { currency: 'USD', _sum: { totalAmount: 100 } },
        { currency: 'EUR', _sum: { totalAmount: 50 } },
      ]);
      const date = new Date('2026-04-01T00:00:00Z');

      const res = await service.calculateMonthlyRevenue(date, ORG_ID);

      expect(res).toEqual([
        { currency: 'USD', total: 100 },
        { currency: 'EUR', total: 50 }
      ]);
      expect(prismaMock.order.groupBy).toHaveBeenCalledWith(expect.objectContaining({
          by: ['currency'],
          where: expect.objectContaining({ orgId: ORG_ID })
      }));
    });

    it('throws BadRequestException for invalid date', async () => {
      await expect(service.calculateMonthlyRevenue(new Date('invalid'), ORG_ID)).rejects.toThrow(BadRequestException);
      await expect(service.calculateMonthlyRevenue(new Date('invalid'), ORG_ID)).rejects.toThrow('Invalid month date');
    });
  });

  describe('bulkUpdateStatus', () => {
    it('updates eligible orders and skips invalid ones silently', async () => {
      prismaMock.order.findUnique
        .mockResolvedValueOnce({ id: '1', orgId: ORG_ID, status: 'pending' })
        .mockResolvedValueOnce({ id: '2', orgId: ORG_ID, status: 'shipped' });
      
      prismaMock.order.updateMany.mockResolvedValueOnce({ count: 1 });

      const res = await service.bulkUpdateStatus(['1', '2'], 'confirmed', ORG_ID);

      expect(res).toBe(1);
      expect(prismaMock.order.updateMany).toHaveBeenCalledTimes(1);
      expect(prismaMock.auditLog.create).toHaveBeenCalledTimes(1);
      expect(redisMock.incr).toHaveBeenCalled();
    });

    it('returns 0 for empty array', async () => {
       const res = await service.bulkUpdateStatus([], 'confirmed', ORG_ID);
       expect(res).toBe(0);
       expect(prismaMock.$transaction).not.toHaveBeenCalled();
    });
  });

  describe('getOrdersForExport', () => {
    it('fetches orders capped at 10000', async () => {
       prismaMock.order.findMany.mockResolvedValueOnce([{ id: '1' }]);
       const res = await service.getOrdersForExport({ status: 'confirmed' }, ORG_ID);

       expect(res).toEqual([{ id: '1' }]);
       expect(prismaMock.order.findMany).toHaveBeenCalledWith(expect.objectContaining({
           where: { orgId: ORG_ID, status: 'confirmed' },
           take: 10000,
           include: { lineItems: true, customer: true, payments: true }
       }));
    });
  });
});

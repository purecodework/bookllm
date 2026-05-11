declare global {
  namespace Express {
    interface Request {
      requestId?: string;
    }
  }
}

export {};

export class ServiceError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
export const fail = (status, code) => { throw new ServiceError(status, code); };

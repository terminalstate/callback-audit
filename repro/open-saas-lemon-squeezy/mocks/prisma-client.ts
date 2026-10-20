// Stand-in for `@prisma/client`: the webhook code only needs the error class for unique-constraint detection.
export const Prisma = {
  PrismaClientKnownRequestError: class extends Error {
    code: string;
    constructor(message: string, { code }: { code: string }) {
      super(message);
      this.code = code;
    }
  },
};
export type PrismaClient = any;

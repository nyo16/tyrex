import {randomUUID} from "node:crypto";

import {op_apply} from "ext:core/ops";

globalThis.Tyrex = {
  _applications: {},
  _handleApplicationResult: (applicationId, result) => {
    Tyrex._applications[applicationId].resolve(result);
    delete Tyrex._applications[applicationId];
  },
  _runtimeId: null,
  apply: (module, functionName, args) => {
    if (typeof module !== "string") {
      throw new Error(`Not a string: ${module}`);
    }
    if (typeof functionName !== "string") {
      throw new Error(`Not a string: ${functionName}`);
    }
    if (!Array.isArray(args)) {
      throw new Error(`Not an array: ${args}`);
    }
    const applicationId = randomUUID();
    const promise = new Promise((resolve, reject) => {
      Tyrex._applications[applicationId] = {reject, resolve};
    });
    op_apply(Tyrex._runtimeId, applicationId, module, functionName, JSON.stringify(args));
    return promise;
  },
};

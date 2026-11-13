import { get, type Writable } from "svelte/store";

// Resolves with the next value that differs from the one current at subscribe time.
// The returned promise carries a cancel() that unsubscribes without resolving: callers
// racing several waiters (Promise.race in ProbeDialog's stepCompleted) must cancel the
// losers, or their subscriptions leak for the rest of the page session.
export function waitForChange<T>(
    writable: Writable<T>
): Promise<T> & { cancel: () => void } {
    let unsubscribe: () => void = () => {};
    let settled = false;
    const promise = new Promise<T>((resolve) => {
        let receivedInitial = false;
        let previousValue: any;
        unsubscribe = writable.subscribe((value) => {
            if (!receivedInitial) {
                receivedInitial = true;
                previousValue = value;
            } else if (value !== previousValue) {
                settled = true;
                resolve(value);
            }
        });
    }) as Promise<T> & { cancel: () => void };
    promise.then(() => unsubscribe());
    promise.cancel = () => {
        if (!settled) unsubscribe();
    };
    return promise;
}

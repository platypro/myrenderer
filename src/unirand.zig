// Random number generator with no repeats
// Adapted from https://gitlab.com/platypro/quizgrind/-/blob/master/libquizgrind/util/unirand.h
//
const std = @import("std");

const Unirand = struct {
    at: u32,
    top: u32,
    offset: u32,
    prime: u32,

    pub fn next(rand: *Unirand) ?u32 {
        var result: ?u32 = undefined;

        if (rand.top > 0 and rand.at < rand.top) {
            result = (rand.at * rand.prime + rand.offset) % (rand.top);
        } else result = null;

        rand.at += 1;
        return result;
    }
};

const primes = [_]u32{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97, 101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151, 157, 163, 167, 173, 179, 181, 191, 193, 197, 199, 211, 223, 227, 229, 233, 239, 241, 251, 257, 263, 269, 271, 277, 281, 283, 293, 307, 311, 313, 317, 331, 337, 347, 349, 353, 359, 367, 373, 379, 383, 389, 397, 401, 409, 419, 421, 431, 433, 439, 443, 449, 457, 461, 463, 467, 479, 487, 491, 499, 503, 509, 521, 523, 541, 601, 659, 733, 809, 863, 941, 1013, 1069, 1151, 1283, 1289, 1367, 1447, 1499, 1579, 1637, 1723, 429494501, 429493501, 429486647, 100001053, 100002421, 10001567 };

pub fn unirand_seed(top: u32) Unirand {
    var rand: Unirand = undefined;

    rand.at = 0;

    const global_rand = std.crypto.random;

    rand.top = top;
    if (top == 1) {
        rand.prime = 1;
        return rand;
    }
    rand.offset = global_rand.int(u32) % (top - 1) + 1;

    var best_prime: u32 = 2;
    for (primes) |prime| {
        if (prime < top and (global_rand.int(u32) % 3 > 0)) {
            best_prime = prime;
        }
    }

    rand.prime = best_prime;

    return rand;
}

pub fn unirand_seed_linear(rand: *Unirand, max: u32) void {
    rand.at = 0;
    rand.offset = 0;
    rand.top = max;
    rand.prime = 1;
}

module dmdscript.RandAA;
//This is a cruedly hacked version, to allow usage of precomputed hashes.
/**An associative array implementation that uses randomized linear congruential
 * probing for collision resolution.  This has the advantage that, no matter
 * how many collisions there are in the modulus hash space, O(1) expected
 * lookup time is guaranteed as long as there are few collisions in full 32-
 * or 64-bit hash space.
 *
 * By:  David Simcha
 *
 * License:
 * Boost Software License - Version 1.0 - August 17th, 2003
 *
 * Permission is hereby granted, free of charge, to any person or organization
 * obtaining a copy of the software and accompanying documentation covered by
 * this license (the "Software") to use, reproduce, display, distribute,
 * execute, and transmit the Software, and to prepare derivative works of the
 * Software, and to permit third-parties to whom the Software is furnished to
 * do so, all subject to the following:
 *
 * The copyright notices in the Software and this entire statement, including
 * the above license grant, this restriction and the following disclaimer,
 * must be included in all copies of the Software, in whole or in part, and
 * all derivative works of the Software, unless such copies or derivative
 * works are solely in the form of machine-executable object code generated by
 * a source language processor.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
 * SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
 * FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
 * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
import std.traits, core.memory, core.exception, std.algorithm, std.conv,
       std.exception, std.math;

/**Exception thrown on missing keys.*/
class KeyError : Exception {
    this(string msg) {
        super(msg);
    }
}

private enum
{
    EMPTY,
    USED,
    REMOVED
}

// It's faster to store the hash if it's expensive to compute, but
// faster not to if it's cheap to compute.
private template shouldStoreHash(K)
{
    enum bool shouldStoreHash = !isFloatingPoint !K && !isIntegral !K;
}
/**Forward range to iterate over keys or values of a RandAA.  Elements can
 * safely be removed (but not added) while iterating over the keys.*/



private void missing_key(K) (K key)
{
    throw new KeyError(text("missing or invalid key ", key));
}

struct aard (K, V, bool useRandom = false)
{
    alias RandAA!(K, V, shouldStoreHash!(K), useRandom) HashMapClass;

    HashMapClass imp_;

    V opIndex(K key)
    {
        if(imp_ !is null)
            return imp_.opIndex(key);
        missing_key(key);
        assert(0);
    }

    V* opIn_r(K k)
    {
        if(imp_ is null)
            return null;
        return imp_.opIn_r(k);
    }
    void opIndexAssign(V value, K k)
    {
        if(imp_ is null)
            imp_ = new HashMapClass();
        imp_.assignNoRehashCheck(k, value);
        imp_.rehash();
    }

    void clear()
    {
        if(imp_ !is null)
            imp_.free();
    }
    void detach()
    {
        imp_ = null;
    }
    bool remove(K k)
    {
        if(imp_ is null)
            return false;
        V val;

        return imp_.remove(k, val);
    }

    bool remove(K k, ref V value)
    {
        if(imp_ is null)
            return false;
        return imp_.remove(k, value);
    }
    @property
    K[] keys()
    {
        if(imp_ is null)
            return null;
        return imp_.keys();
    }

    @property aard allocate()
    {
        aard newAA;

        newAA.imp_ = new HashMapClass();

        return newAA;
    }
    @property void loadRatio(double cap)
    {
        // dummy
    }
    @property void capacity(size_t cap)
    {
        // dummy
    }

    @property
    V[] values()
    {
        if(imp_ is null)
            return null;
        return imp_.values();
    }

    V get(K k)
    {
        V* p = opIn_r(k);
        if(p !is null)
        {
            return *p;
        }
        return V.init;
    }

    bool get(K k, ref V val)
    {
        if(imp_ !is null)
        {
            V* p = opIn_r(k);
            if(p !is null)
            {
                val = *p;
                return true;
            }
        }
        val = V.init;
        return false;
    }

    @property size_t length()
    {
        if(imp_ is null)
            return 0;
        return imp_._length;
    }


    public int opApply(int delegate(ref V value) dg)
    {
        return (imp_ !is null) ? imp_.opApply(dg) : 0;
    }

    public int opApply(int delegate(ref K key, ref V value) dg)
    {
        return (imp_ !is null) ? imp_.opApply(dg) : 0;
    }
}



/**An associative array class that uses randomized probing and open
 * addressing.  K is the key type, V is the value type, storeHash
 * determines whether the hash of each key is stored in the array.  This
 * increases space requirements, but allows for faster rehashing.  By
 * default, the hash is stored unless the array is an array of floating point
 * or integer types.
 */
final class RandAA(K, V, bool storeHash = shouldStoreHash!(K), bool useRandom = false)
{
private:

    // Store keys, values in parallel arrays.  This prevents us from having
    // alignment overhead and prevents the GC from scanning values if only
    // keys have pointers, or vice-versa.
    K* _keys;
    V* vals;
    ubyte* flags;

    static if(storeHash)
    {
        hash_t* hashes;  // For fast reindexing.
    }

    size_t mask;    // easy modular 2
    size_t clock;   // calculate with size
    size_t _length; // Logical size
    size_t space;   // Storage space
    size_t nDead;   // Number of elements removed.
    //TypeInfo  ti_;

    // Good values for a linear congruential random number gen.  The modulus
    // is implicitly uint.max + 1, meaning that we take advantage of overflow
    // to avoid a div instruction.
    enum : size_t  { mul = 1103515245U, add = 12345U }
    enum : size_t  { PERTURB_SHIFT = 32 }

    // Optimized for a few special cases to avoid the virtual function call
    // to TypeInfo.getHash().
    hash_t getHash(K key) const
    {
        static if(is (K : long) && K.sizeof <= hash_t.sizeof)
        {
            hash_t hash = cast(hash_t)key;
        }
        else
            static if(is (typeof(key.toHash())))
            {
                hash_t hash = key.toHash();
            }
            else
            {
                hash_t hash = typeid(K).getHash(cast(const (void)*)&key);
            }

        return hash;
    }


    static if(storeHash)
    {
        size_t findExisting(ref K key)  const
        {
            immutable hashFull = getHash(key);
            size_t pos = hashFull & mask;
            static if(useRandom)
                size_t rand = hashFull + 1;
            else // static if (P == "perturb")
            {
                size_t perturb = hashFull;
                size_t i = pos;
            }

            uint flag = void;
            while(true)
            {
                flag = flags[pos];
                if(flag == EMPTY || (hashFull == hashes[pos] && key == _keys[pos] && flag != EMPTY))
                {
                    break;
                }
                static if(useRandom)
                {
                    rand = rand * mul + add;
                    pos = (rand + hashFull) & mask;
                }
                else // static if (P == "perturb")
                {
                    i = (i * 5 + perturb + 1);
                    perturb /= PERTURB_SHIFT;
                    pos = i & mask;
                }
            }
            return (flag == USED) ? pos : size_t.max;
        }

        size_t findForInsert(ref K key, immutable hash_t hashFull)
        {
            size_t pos = hashFull & mask;
            static if(useRandom)
                size_t rand = hashFull + 1;
            else //static if (P == "perturb")
            {
                size_t perturb = hashFull;
                size_t i = pos;
            }

            while(true)
            {
                if(flags[pos] != USED || (hashes[pos] == hashFull && _keys[pos] == key))
                {
                    break;
                }
                static if(useRandom)
                {
                    rand = rand * mul + add;
                    pos = (rand + hashFull) & mask;
                }
                else //static if (P == "perturb")
                {
                    i = (i * 5 + perturb + 1);
                    perturb /= PERTURB_SHIFT;
                    pos = i & mask;
                }
            }

            hashes[pos] = hashFull;
            return pos;
        }
    }
    else
    {
        size_t findExisting(ref K key) const
        {
            immutable hashFull = getHash(key);
            size_t pos = hashFull & mask;
            static if(useRandom)
                size_t rand = hashFull + 1;
            else //static if (P == "perturb")
            {
                size_t perturb = hashFull;
                size_t i = pos;
            }

            uint flag = void;
            while(true)
            {
                flag = flags[pos];
                if(flag == EMPTY || (_keys[pos] == key && flag != EMPTY))
                {
                    break;
                }
                static if(useRandom)
                {
                    rand = rand * mul + add;
                    pos = (rand + hashFull) & mask;
                }
                else // static if (P == "perturb")
                {
                    i = (i * 5 + perturb + 1);
                    perturb /= PERTURB_SHIFT;
                    pos = i & mask;
                }
            }
            return (flag == USED) ? pos : size_t.max;
        }

        size_t findForInsert(ref K key, immutable hash_t hashFull) const
        {
            size_t pos = hashFull & mask;
            static if(useRandom)
            {
                size_t rand = hashFull + 1;
            }
            else
            {
                size_t perturb = hashFull;
                size_t i = pos;
            }



            while(flags[pos] == USED && _keys[pos] != key)
            {
                static if(useRandom)
                {
                    rand = rand * mul + add;
                    pos = (rand + hashFull) & mask;
                }
                else
                {
                    i = (i * 5 + perturb + 1);
                    perturb /= PERTURB_SHIFT;
                    pos = i & mask;
                }
            }

            return pos;
        }
    }

    void assignNoRehashCheck(ref K key, ref V val, hash_t hashFull)
    {
        size_t i = findForInsert(key, hashFull);
        vals[i] = val;
        immutable uint flag = flags[i];
        if(flag != USED)
        {
            if(flag == REMOVED)
            {
                nDead--;
            }
            _length++;
            flags[i] = USED;
            _keys[i] = key;
        }
    }

    void assignNoRehashCheck(ref K key, ref V val)
    {
        hash_t hashFull = getHash(key);
        size_t i = findForInsert(key, hashFull);
        vals[i] = val;
        immutable uint flag = flags[i];
        if(flag != USED)
        {
            if(flag == REMOVED)
            {
                nDead--;
            }
            _length++;
            flags[i] = USED;
            _keys[i] = key;
        }
    }

    // Dummy constructor only used internally.
    this(bool dummy) {}

public:

    static size_t getNextP2(size_t n)
    {
        // get the powerof 2 > n

        size_t result = 16;
        while(n >= result)
        {
            result *= 2;
        }
        return result;
    }
    /**Construct an instance of RandAA with initial size initSize.
     * initSize determines the amount of slots pre-allocated.*/
    this(size_t initSize = 10) {
        //initSize = nextSize(initSize);
        space = getNextP2(initSize);
        mask = space - 1;
        _keys = (new K[space]).ptr;
        vals = (new V[space]).ptr;

        static if(storeHash)
        {
            hashes = (new hash_t[space]).ptr;
        }

        flags = (new ubyte[space]).ptr;
    }

    ///
    void rehash()
    {
        if(cast(float)(_length + nDead) / space < 0.7)
        {
            return;
        }
        reserve(space + 1);
    }

    /**Reserve enough space for newSize elements.  Note that the rehashing
     * heuristics do not guarantee that no new space will be allocated before
     * newSize elements are added.
     */
    private void reserve(size_t newSize)
    {
        scope typeof(this)newTable = new typeof(this)(newSize);

        foreach(i; 0..space)
        {
            if(flags[i] == USED)
            {
                static if(storeHash)
                {
                    newTable.assignNoRehashCheck(_keys[i], vals[i], hashes[i]);
                }
                else
                {
                    newTable.assignNoRehashCheck(_keys[i], vals[i]);
                }
            }
        }

        // Can't free vals b/c references to it could escape.  Let GC
        // handle it.
        GC.free(cast(void*)this._keys);
        GC.free(cast(void*)this.flags);
        GC.free(cast(void*)this.vals);

        static if(storeHash)
        {
            GC.free(cast(void*)this.hashes);
        }

        foreach(ti, elem; newTable.tupleof)
        {
            this.tupleof[ti] = elem;
        }
    }

    /**Throws a KeyError on unsuccessful key search.*/
    ref V opIndex(K index)
    {
        size_t i = findExisting(index);
        if(i == size_t.max)
        {
            throw new KeyError("Could not find key " ~ to !string(index));
        }
        else
        {
            return vals[i];
        }
    }
/+ I have to insure there is no returns by value, rude hack
    /**Non-ref return for const instances.*/
    V opIndex(K index)
    {
        size_t i = findExisting(index);
        if(i == size_t.max)
        {
            throw new KeyError("Could not find key " ~ to !string(index));
        }
        else
        {
            return vals[i];
        }
    }
+/
	///Hackery
	V* findExistingAlt(ref K key, hash_t hashFull){
            size_t pos = hashFull & mask;
            static if(useRandom)
                size_t rand = hashFull + 1;
            else // static if (P == "perturb")
            {
                size_t perturb = hashFull;
                size_t i = pos;
            }

            uint flag = void;
            while(true)
            {
                flag = flags[pos];
                if(flag == EMPTY || (hashFull == hashes[pos] && key == _keys[pos] && flag != EMPTY))
                {
                    break;
                }
                static if(useRandom)
                {
                    rand = rand * mul + add;
                    pos = (rand + hashFull) & mask;
                }
                else // static if (P == "perturb")
                {
                    i = (i * 5 + perturb + 1);
                    perturb /= PERTURB_SHIFT;
                    pos = i & mask;
                }
            }
            return (flag == USED) ? &vals[pos] : null;
	}
	void insertAlt(ref K key, ref V val, hash_t hashFull){
		assignNoRehashCheck(key, val, hashFull);
		rehash();
	}

    ///
    void opIndexAssign(V val, K index)
    {
        assignNoRehashCheck(index, val);
        rehash();
    }
    struct KeyValRange (K, V, bool storeHash, bool vals) {
private:
        static if(vals)
        {
            alias V T;
        }
        else
        {
            alias K T;
        }
        size_t index = 0;
        RandAA aa;
public:
        this(RandAA aa) {
            this.aa = aa;
            while(aa.flags[index] != USED && index < aa.space)
            {
                index++;
            }
        }

        ///
        T front()
        {
            static if(vals)
            {
                return aa.vals[index];
            }
            else
            {
                return aa._keys[index];
            }
        }

        ///
        void popFront()
        {
            index++;
            while(aa.flags[index] != USED && index < aa.space)
            {
                index++;
            }
        }

        ///
        bool empty()
        {
            return index == aa.space;
        }

        string toString()
        {
            char[] ret = "[".dup;
            auto copy = this;
            foreach(elem; copy)
            {
                ret ~= to !string(elem);
                ret ~= ", ";
            }

            ret[$ - 2] = ']';
            ret = ret[0..$ - 1];
            auto retImmutable = assumeUnique(ret);
            return retImmutable;
        }
    }
    alias KeyValRange!(K, V, storeHash, false) key_range;
    alias KeyValRange!(K, V, storeHash, true) value_range;

    /**Does not allocate.  Returns a simple forward range.*/
    key_range keyRange()
    {
        return key_range(this);
    }

    /**Does not allocate.  Returns a simple forward range.*/
    value_range valueRange()
    {
        return value_range(this);
    }

    /**Removes an element from this.  Elements *may* be removed while iterating
     * via .keys.*/
    V remove(K index)
    {
        size_t i = findExisting(index);
        if(i == size_t.max)
        {
            throw new KeyError("Could not find key " ~ to !string(index));
        }
        else
        {
            _length--;
            nDead++;
            flags[i] = REMOVED;
            return vals[i];
        }
    }

    V[] values()
    {
        size_t i = 0;
        V[] result = new V[this._length];

        foreach(k, v; this)
            result[i++] = v;
        return result;
    }
    K[] keys()
    {
        size_t i = 0;
        K[] result = new K[this._length];

        foreach(k, v; this)
            result[i++] = k;
        return result;
    }
    bool remove(K index, ref V value)
    {
        size_t i = findExisting(index);
        if(i == size_t.max)
        {
            return false;
        }
        else
        {
            _length--;
            nDead++;
            flags[i] = REMOVED;
            value = vals[i];
            return true;
        }
    }
    /**Returns null if index is not found.*/
    V* opIn_r(K index)
    {
        size_t i = findExisting(index);
        if(i == size_t.max)
        {
            return null;
        }
        else
        {
            return vals + i;
        }
    }

    /**Iterate over keys, values in lockstep.*/
    int opApply(int delegate(ref K, ref V) dg)
    {
        int result;
        foreach(i, k; _keys[0..space])
            if(flags[i] == USED)
            {
                result = dg(k, vals[i]);
                if(result)
                {
                    break;
                }
            }
        return result;
    }

    private template DeconstArrayType(T)
    {
        static if(isStaticArray!(T))
        {
            alias typeof(T.init[0])[] type;             //the equivalent dynamic array
        }
        else
        {
            alias T type;
        }
    }

    alias DeconstArrayType!(K).type K_;
    alias DeconstArrayType!(V).type V_;

    public int opApply(int delegate(ref V_ value) dg)
    {
        return opApply((ref K_ k, ref V_ v) { return dg(v); });
    }

    void clear()
    {
        free();
    }
    /**Allows for deleting the contents of the array manually, if supported
     * by the GC.*/
    void free()
    {
        GC.free(cast(void*)this._keys);
        GC.free(cast(void*)this.vals);
        GC.free(cast(void*)this.flags);

        static if(storeHash)
        {
            GC.free(cast(void*)this.hashes);
        }
    }

    ///
    size_t length()
    {
        return _length;
    }
}

import std.random, std.exception, std.stdio;
/*
   // Test it out.
   void unit_tests() {
    string[string] builtin;
    auto myAA = new RandAA!(string, string)();

    foreach(i; 0..100_000) {
        auto myKey = randString(20);
        auto myVal = randString(20);
        builtin[myKey] = myVal;
        myAA[myKey] = myVal;
    }

    enforce(myAA.length == builtin.length);
    foreach(key; myAA.keys) {
        enforce(myAA[key] == builtin[key]);
    }

    auto keys = builtin.keys;
    randomShuffle(keys);
    foreach(toRemove; keys[0..1000]) {
        builtin.remove(toRemove);
        myAA.remove(toRemove);
    }


    myAA.rehash();
    enforce(myAA.length == builtin.length);
    foreach(k, v; builtin) {
        enforce(k in myAA);
        enforce( *(k in myAA) == v);
    }

    string[] myValues;
    foreach(val; myAA.values) {
        myValues ~= val;
    }

    string[] myKeys;
    foreach(key; myAA.keys) {
        myKeys ~= key;
    }

    auto builtinKeys = builtin.keys;
    auto builtinVals = builtin.values;
    sort(builtinVals);
    sort(builtinKeys);
    sort(myKeys);
    sort(myValues);
    enforce(myKeys == builtinKeys);
    enforce(myValues == builtinVals);

    writeln("Passed all tests.");
   }

 */

/// Framework Core RSA Support
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit mormot.crypt.rsa;

{
  *****************************************************************************

   Rivest-Shamir-Adleman (RSA) Public-Key Cryptography
    - RSA Oriented Big-Integer Computation
    - RSA Low-Level Cryptography Functions

  *****************************************************************************
}

interface

{$I ..\mormot.defines.inc}

uses
  classes,
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.rtti,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.buffers;
  
{ Implementation notes:
  - loosely based on fpTLSBigInt / fprsa units from the FPC RTL - but the whole
    design and core methods have been rewritten from scratch in modern OOP
  - we use half-registers (HalfUInt) for efficient computation on most systems
}

{ **************** RSA Oriented Big-Integer Computation }

type
  /// exception class raised by this unit
  ERsaException = class(ESynException);

const
  /// maximum HalfUInt value + 1
  RSA_RADIX = PtrUInt({$ifdef CPU32} $10000 {$else} $100000000 {$endif});
  /// maximum PtrUInt value - 1
  RSA_MAX = PtrUInt(-1);

  /// number of bytes in a HalfUInt, i.e. 2 on CPU32 and 4 on CPU64
  HALF_BYTES = SizeOf(HalfUInt);
  /// number of bits in a HalfUInt, i.e. 16 on CPU32 and 32 on CPU64
  HALF_BITS = HALF_BYTES * 8;
  /// number of power of two bits in a HalfUInt, i.e. 4 on CPU32 and 5 on CPU64
  HALF_SHR = {$ifdef CPU32} 4 {$else} 5 {$endif};

type
  PPBigInt = ^PBigInt;
  PBigInt = ^TBigInt;

  TRsaContext = class;

  /// store one Big Integer value with proper COW support
  // - each value is owned as PBigInt by an associated TRsaContext instance
  // - you should call TBigInt.Release() once done with any instance
  {$ifdef USERECORDWITHMETHODS}
  TBigInt = record
  {$else}
  TBigInt = object
  {$endif USERECORDWITHMETHODS}
  private
    fNextFree: PBigInt; // next bigint in the Owner free instance cache
    procedure Resize(n: integer; nozero: boolean = false);
    function FindMaxExponentIndex: integer;
    procedure SetPermanent;
    procedure ResetPermanent;
    function TruncateMod(modulus: integer): PBigInt;
      {$ifdef HASINLINE} inline; {$endif}
  public
    /// the associated Big Integer RSA context
    // - used to store modulo constants, and maintain an internal instance cache
    Owner: TRsaContext;
    /// number of HalfUInt in this Big Integer value
    Size: integer;
    /// number of HalfUInt allocated for this Big Integer value
    Capacity: integer;
    /// internal reference counter
    // - equals -1 for permanent/constant storage
    RefCnt: integer;
    /// raw access to the actual HalfUInt data
    Value: PHalfUIntArray;
    /// comparison with another Big Integer value
    // - values should have been Trim-med for the size to match
    function Compare(b: PBigInt): integer;
    /// make a COW instance, increasing RefCnt
    function Copy: PBigInt;
      {$ifdef HASINLINE} inline; {$endif}
    /// allocate a new Big Integer value with the same data as an existing one
    function Clone: PBigInt;
    /// decreases the value RefCnt, saving it in the internal FreeList once done
    procedure Release;
    /// a wrapper to ResetPermanent then Release
    procedure ResetPermanentAndRelease;
    /// export a Big Integer value into a binary buffer
    procedure Save(data: PByteArray; bytes: integer; andrelease: boolean); overload;
    /// export a Big Integer value into a binary RawByteString
    function Save(andrelease: boolean = false): RawByteString; overload;
    /// delete any meaningless leading zeros and return self
    function Trim: PBigInt;
      {$ifdef HASSAFEINLINE} inline; {$endif}
    /// quickly search if contains 0
    function IsZero: boolean;
      {$ifdef HASINLINE} inline; {$endif}
    /// check if a given bit is set to 1
    function BitIsSet(bit: PtrUInt): boolean;
      {$ifdef HASINLINE} inline; {$endif}
    /// search the position of the first bit set
    function BitCount: integer;
    /// shift right the internal data HalfUInt by a number of slots
    function RightShift(n: integer): PBigInt;
    /// shift left the internal data HalfUInt by a number of slots
    function LeftShift(n: integer): PBigInt;
    /// compute the sum of two Big Integer values
    // - returns self := self + b as result
    // - will eventually release the b instance
    function Add(b: PBigInt): PBigInt;
    /// compute the difference of two Big Integer values
    // - returns self := abs(self - b) as result, and NegativeResult^ as its sign
    // - will eventually release the b instance
    function Substract(b: PBigInt; NegativeResult: PBoolean = nil): PBigInt;
    /// division or modulo computation
    // - self is the numerator
    // - if ComputeMod is false, v is the denominator; otherwise, is the modulus
    // - will eventually release the v instance
    function Divide(v: PBigInt; ComputeMod: boolean = false): PBigInt;
    /// standard multiplication between two Big Integer values
    // - will eventually release both self and b instances
    function Multiply(b: PBigInt; InnerPartial: PtrInt = 0;
      OuterPartial: PtrInt = 0): PBigInt;
    /// multiply by an unsigned integer value
    // - returns self := self * b
    // - will eventually release the self instance
    function IntMultiply(b: HalfUInt): PBigInt;
    /// divide by an unsigned integer value
    // - returns self := self div b
    function IntDivide(b: HalfUInt): PBigInt;
    /// return the Big integer value as hexadecimal
    function ToText: RawUtf8;
  end;

  /// define Normal, P and Q pre-computed modulos
  TRsaModulo = (
    rmN,
    rmP,
    rmQ);

  /// store Normal, P and Q pre-computed modulos as PBigInt
  TRsaModulos = array[TRsaModulo] of PBigInt;

  /// store one Big Integer computation context for RSA
  // - will maintain its own set of reference-counted Big Integer values
  TRsaContext = class
  private
    /// list of released PBigInt instance, ready to be re-used by Allocate()
    fFreeList: PBigInt;
    /// the radix used
    fRadix: PBigInt;
    /// contains Modulus
    fMod: TRsaModulos;
    /// contains mu
    fMu: TRsaModulos;
    /// contains b(k+1)
    fBk1: TRsaModulos;
    /// contains the normalized storage
    fNormMod: TRsaModulos;
  public
    /// used by the sliding-window algorithm
    G: PPBigInt;
    /// the size of the sliding window
    Window: Integer;
    /// number of active PBigInt
    ActiveCount: Integer;
    /// number of PBigInt instances stored in the internal instances cache
    FreeCount: Integer;
    /// the RSA modulo we are using
    CurrentModulo: TRsaModulo;
    /// initialize this Big Integer context
    constructor Create(Size: integer); reintroduce;
    /// finalize this Big Integer context memory
    destructor Destroy; override;
    /// allocate a new zeroed Big Integer value of the specified precision
    // - n is the number of TBitInt.Value[] items to initialize
    function Allocate(n: integer; nozero: boolean = false): PBigint;
    /// allocate a new Big Integer value from a 16/32-bit unsigned integer
    function AllocateFrom(v: HalfUInt): PBigInt;
    /// allocate and import a Big Integer value from a big-endian binary buffer
    function Load(data: PByteArray; bytes: integer): PBigInt; overload;
    /// pre-compute some of the internal constant slots for a given modulo
    procedure SetModulo(b: PBigInt; modulo: TRsaModulo);
    /// release the internal constant slots for a given modulo
    procedure ResetModulo(modulo: TRsaModulo);
    /// compute the Barret reduction of a Big Integer value
    function Barret(b: PBigint): PBigInt;
  end;

const
  BIGINT_ZERO_VALUE: HalfUInt = 0;
  BIGINT_ONE_VALUE:  HalfUInt = 1;

  /// constant 0 as Big Integer value
  BIGINT_ZERO: TBigInt = (
    Size: {%H-}1;
    RefCnt: {%H-}-1;
    Value: {%H-}@BIGINT_ZERO_VALUE);

  /// constant 1 as Big Integer value
  BIGINT_ONE: TBigInt = (
    Size: {%H-}1;
    RefCnt: {%H-}-1;
    Value: {%H-}@BIGINT_ONE_VALUE);

/// branchless comparison of two Big Integer values
function CompareBI(A, B: HalfUInt): integer;
  {$ifdef HASINLINE} inline; {$endif}


{ **************** RSA Low-Level Cryptography Functions }


implementation


{ **************** RSA Oriented Big-Integer Computation }

function Min(a, b: integer): integer;
  {$ifdef HASINLINE} inline; {$endif}
begin
  if a < b then
    result := a
  else
    result := b;
end;

function Max(a, b: integer): integer;
  {$ifdef HASINLINE} inline; {$endif}
begin
  if a > b then
    result := a
  else
    result := b;
end;

function CompareBI(A, B: HalfUInt): integer;
begin
  result := ord(A > B) - ord(A < B);
end;

procedure TBigInt.Resize(n: integer; nozero: boolean);
begin
  if n > Capacity then
  begin
    Capacity := NextGrow(n); // reserve a bit more for faster size-up
    ReAllocMem(Value, Capacity * HALF_BYTES);
  end;
  if not nozero and
     (n > Size) then
    FillCharFast(Value[Size], (n - Size) * HALF_BYTES, 0);
  Size := n;
end;

function TBigInt.Trim: PBigInt;
var
  n: PtrInt;
begin
  n := Size;
  while (n > 1) and
        (Value[n - 1] = 0) do // delete any leading 0
    dec(n);
  Size := n;
  result := @self;
end;

function TBigInt.IsZero: boolean;
var
  i: PtrInt;
  p: PHalfUIntArray;
begin
  if @self <> nil then
  begin
    p := Value;
    if p <> nil then
    begin
      result := false;
      for i := 0 to Size - 1 do
        if p[i] <> 0 then
          exit;
    end;
  end;
  result := true;
end;

function TBigInt.BitIsSet(bit: PtrUInt): boolean;
begin
  result := Value[bit shr HALF_SHR] and
              (1 shl (bit and pred(HALF_BITS))) <> 0;
end;

function TBigInt.BitCount: integer;
var
  i: PtrInt;
  c: HalfUInt;
begin
  result := 0;
  i := Size - 1;
  while Value[i] = 0 do
  begin
    dec(i);
    if i < 0 then
      exit;
  end;
  result := i * HALF_BITS;
  c := Value[i];
  repeat
    inc(result);
    c := c shr 1;
  until c = 0;
end;

function TBigInt.Compare(b: PBigInt): integer;
var
  i: PtrInt;
begin
  result := CompareInteger(Size, b^.Size);
  if result <> 0 then
    exit;
  for i := Size - 1 downto 0 do
  begin
    result := CompareBI(Value[i], b^.Value[i]);
    if result <> 0 then
      exit;
  end;
end;

procedure TBigInt.SetPermanent;
begin
  if RefCnt <> 1 then
    raise ERsaException.CreateUtf8(
      'TBigInt.SetPermanent(%): RefCnt=%', [@self, RefCnt]);
  RefCnt := -1;
end;

procedure TBigInt.ResetPermanent;
begin
  if RefCnt >= 0 then
    raise ERsaException.CreateUtf8(
      'TBigInt.ResetPermanent(%): RefCnt=%', [@self, RefCnt]);
  RefCnt := 1;
end;

function TBigInt.RightShift(n: integer): PBigInt;
begin
  if n > 0 then
  begin
    dec(Size, n);
    if Size <= 0 then
    begin
      Size := 1;
      Value[0] := 0;
    end
    else
      MoveFast(Value[n], Value[0], Size * HALF_BYTES);
  end;
  result := @self;
end;

function TBigInt.LeftShift(n: integer): PBigInt;
var
  s: integer;
begin
  if n > 0 then
  begin
    s := Size;
    Resize(s + n, {nozero=}true);
    MoveFast(Value[0], Value[n], s * HALF_BYTES);
    FillCharFast(Value[0], n * HALF_BYTES, 0);
  end;
  result := @self;
end;

function TBigInt.TruncateMod(modulus: integer): PBigInt;
begin
  if Size > modulus then
    Size := modulus;
  result := @self;
end;

function TBigInt.Copy: PBigInt;
begin
  if RefCnt >= 0 then
    inc(RefCnt);
  result := @self;
end;

function TBigInt.FindMaxExponentIndex: integer;
var
  mask, v: HalfUInt;
begin
  result := HALF_BITS - 1;
  mask := RSA_RADIX shr 1;
  v := Value[Size - 1];
  repeat
    if (v and mask) <> 0 then
      break;
    mask := mask shr 1;
    dec(result);
    if result < 0 then
      exit;
  until false;
  inc(result, (Size - 1) * HALF_BITS);
end;


procedure TBigInt.Release;
begin
  if (@self = nil) or
     (RefCnt < 0) then
    exit;
  dec(RefCnt);
  if RefCnt > 0 then
    exit;
  fNextFree := Owner.fFreeList; // store this value in the internal free list
  Owner.fFreeList := @self;
  inc(Owner.FreeCount);
  dec(Owner.ActiveCount);
end;

procedure TBigInt.ResetPermanentAndRelease;
begin
  ResetPermanent;
  Release;
end;

function TBigInt.Clone: PBigInt;
begin
  result := Owner.Allocate(Size, {nozero=}true);
  MoveFast(Value[0], result^.Value[0], Size * HALF_BYTES);
end;

procedure TBigInt.Save(data: PByteArray; bytes: integer; andrelease: boolean);
var
  i, k: PtrInt;
  c: cardinal;
  j: byte;
begin
  FillCharFast(data^, bytes, 0);
  k := bytes - 1;
  for i := 0 to Size - 1 do
  begin
    c := Value[i];
    if k >= 0 then
      for j := 0 to HALF_BYTES - 1 do
      begin
        data[k] := c shr (j * 8);
        dec(k);
        if k < 0 then
          break;
      end;
  end;
  if andrelease then
    Release;
end;

function TBigInt.Save(andrelease: boolean): RawByteString;
begin
  FastSetRawByteString(result, nil, Size * HALF_BYTES);
  Save(pointer(result), length(result), andrelease);
end;

function TBigInt.Add(b: PBigInt): PBigInt;
var
  n: integer;
  pa, pb: PHalfUInt;
  v: PtrUInt;
begin
  if not b^.IsZero then
  begin
    n := Max(Size, b^.Size);
    Resize(n + 1, {nozero=}true);
    b^.Resize(n);
    pa := pointer(Value);
    pb := pointer(b^.Value);
    v := 0;
    repeat
      inc(v, PtrUInt(pa^) + pb^);
      pa^ := v;
      v := v shr HALF_BITS; // branchless carry propagation
      inc(pa);
      inc(pb);
      dec(n);
    until n = 0;
    pa^ := v;
  end;
  b.Release;
  result := Trim;
end;

function TBigInt.Substract(b: PBigInt; NegativeResult: PBoolean): PBigInt;
var
  n: integer;
  pa, pb: PHalfUInt;
  v: PtrUInt;
begin
  n := Size;
  b^.Resize(n);
  pa := pointer(Value);
  pb := pointer(b^.Value);
  v := 0;
  repeat
    v := PtrUInt(pa^) - pb^ - v;
    pa^ := v;
    v := ord((v shr HALF_BITS) <> 0); // branchless carry
    inc(pa);
    inc(pb);
    dec(n);
  until n = 0;
  if NegativeResult <> nil then
    NegativeResult^ := v <> 0;
  b.Release;
  result := Trim;
end;

function TBigInt.IntMultiply(b: HalfUInt): PBigInt;
var
  r: PHalfUInt;
  v, m: PtrUInt;
  i: PtrInt;
begin
  result := Owner.Allocate(Size + 1, true);
  r := pointer(result^.Value);
  v := 0;
  m := b;
  for i := 0 to Size - 1 do
  begin
    inc(v, PtrUInt(Value[i]) * m);
    r^ := v;
    v := v shr HALF_BITS; // carry
    inc(r);
  end;
  r^ := v;
  Release;
  result^.Trim;
end;

function TBigInt.IntDivide(b: HalfUInt): PBigInt;
var
  r, d: PtrUInt;
  i: PtrInt;
begin
  r := 0;
  for i := Size - 1 downto 0 do
  begin
    r := (r shl HALF_BITS) + Value[i];
    d := r div b;
    Value[i] := d;
    dec(r, d * b); // fast r := r mod b
  end;
  result := Trim;
end;

function TBigInt.ToText: RawUtf8;
begin
  result := BinToHexDisplay(pointer(Value), Size * HALF_BYTES);
end;

function TBigInt.Divide(v: PBigInt; ComputeMod: boolean): PBigInt;
var
  d, inner, dash: HalfUInt;
  neg: boolean;
  j, m, n, orgsiz: integer;
  p: PHalfUInt;
  u, quo, tmp: PBigInt;
begin
  if ComputeMod and
     (Compare(v) < 0) then
  begin
    v.Release;
    result := @self; // just return u if u < v
    exit;
  end;
  m := Size - v^.Size;
  n := v^.Size + 1;
  orgsiz := Size;
  quo := Owner.Allocate(m + 1);
  tmp := Owner.Allocate(n);
  v.Trim;
  d := RSA_RADIX div (PtrUInt(v^.Value[v^.Size - 1]) + 1);
  u := Clone;
  if d > 1 then
  begin
    // Normalize
    u := u.IntMultiply(d);
    if ComputeMod and
       not Owner.fNormMod[Owner.CurrentModulo].IsZero then
      v := Owner.fNormMod[Owner.CurrentModulo]
    else
      v := v.IntMultiply(d);
  end;
  if orgsiz = u^.Size then
    u.Resize(orgsiz + 1); // allocate additional digit
  for j := 0 to m do
  begin
    // Get a temporary short version of u
    MoveFast(u^.Value[u^.Size - n - j], tmp^.Value[0],
               n * HALF_BYTES);
    // Calculate q'
    if tmp^.Value[tmp^.Size - 1] = v^.Value[v^.Size - 1] then
      dash := RSA_RADIX - 1
    else
    begin
      dash := (PtrUInt(tmp^.Value[tmp^.Size - 1]) * RSA_RADIX +
              tmp^.Value[tmp^.Size - 2]) div v^.Value[v^.Size - 1];
      if (v^.Size > 1) and
         (v^.Value[v^.Size - 2] > 0) then
      begin
        inner := (RSA_RADIX * tmp^.Value[tmp^.Size - 1] +
            tmp^.Value[tmp^.Size - 2] -
            PtrUInt(dash) * v^.Value[v^.Size - 1]) and $ffffffff;
        if (PtrUInt(v^.Value[v^.Size - 2]) * dash) >
            (PtrUInt(inner) * RSA_RADIX +
             tmp^.Value[tmp^.Size - 3]) then
          dec(dash);
      end;
    end;
    p := @quo^.Value[quo^.Size - j - 1];
    if dash > 0 then
    begin
      // Multiply and subtract
      tmp := tmp.Substract(v.Copy.IntMultiply(dash), @neg);
      tmp.Resize(n);
      p^ := dash;
      if neg then
      begin
        // Add back
        dec(p^);
        tmp := tmp.Add(v.Copy);
        // Lop off the carry
        dec(tmp^.Size);
        dec(v^.Size);
      end;
    end
    else
      p^ := 0;
    // Copy back to u
    MoveFast(tmp^.Value[0], u^.Value[u^.Size - n - j],
      n * HALF_BYTES);
  end;
  tmp.Release;
  v.Release;
  if ComputeMod then
  begin
    // return the remainder
    quo.Release;
    result := u.Trim.IntDivide(d);
  end
  else
  begin
    // return the quotient
    u.Release;
    result := quo.Trim;
  end
end;

function TBigInt.Multiply(b: PBigInt; InnerPartial, OuterPartial: PtrInt): PBigInt;
var
  r: PBigInt;
  i, j, k, n: PtrInt;
  v: PtrUInt;
begin
  n := Size;
  r := Owner.Allocate(n + b^.Size);
  for i := 0 to b^.Size - 1 do
  begin
    v := 0; // initial carry value
    k := i;
    j := 0;
    if (OuterPartial <> 0) and
       (OuterPartial > i) and
       (OuterPartial < n) then
    begin
      k := OuterPartial - 1;
      j := k - 1;
    end;
    repeat
      if (InnerPartial > 0) and
         (k >= InnerPartial) then
        break;
      inc(v, PtrUInt(r^.Value[k]) +
             PtrUInt(Value[j]) * b^.Value[i]);
      r^.Value[k] := v;
      inc(k);
      v := v shr HALF_BITS; // carry
      inc(j);
    until j >= n;
    r^.Value[k] := v;
  end;
  Release;
  b.Release;
  result := r.Trim;
end;


{ TRsaContext }

constructor TRsaContext.Create(Size: integer);
begin
  fRadix := Allocate(2, {nozero=}true);
  fRadix^.Value[0] := 0;
  fRadix^.Value[1] := 1;
  fRadix^.SetPermanent;
end;

destructor TRsaContext.Destroy;
var
  b, next : PBigInt;
begin
  fRadix.ResetPermanentAndRelease;
  b := fFreeList;
  while b <> nil do
  begin
    next := b^.fNextFree;
    if b^.Value<>nil then
      FreeMem(b^.Value);
    FreeMem(b);
    b := next;
  end;
  inherited Destroy;
end;

function TRsaContext.AllocateFrom(v: HalfUInt): PBigInt;
begin
  result := Allocate(1, {nozero=}true);
  result^.Value[0] := v;
end;

function TRsaContext.Allocate(n: integer; nozero: boolean): PBigint;
begin
  if self = nil then
    raise ERsaException.CreateUtf8('TBigInt.Allocate(%): Owner=nil', [n]);
  result := fFreeList;
  if result <> nil then
  begin
    // we can recycle a pre-allocated buffer
    if result^.RefCnt <> 0 then
      raise ERsaException.CreateUtf8(
        'TBigInt.Allocate(%): % RefCnt=%', [n, result, result^.RefCnt]);
    fFreeList := result^.fNextFree;
    dec(FreeCount);
    result.Resize(n, {nozero=}true);
  end
  else
  begin
    // we need to allocate a new buffer
    New(result);
    result^.Owner := self;
    result^.Size := n;
    result^.Capacity := n * 2; // with some initial over-allocatation
    GetMem(result^.Value, result^.Capacity * HALF_BYTES);
  end;
  result^.RefCnt := 1;
  result^.fNextFree := nil;
  if not nozero then
    FillCharFast(result^.Value[0], n * HALF_BYTES, 0); // zeroed
  inc(ActiveCount);
end;

function TRsaContext.Load(data: PByteArray; bytes: integer): PBigInt;
var
  i, o: PtrInt;
  j: byte;
begin
  result := Allocate((bytes + HALF_BYTES - 1) div HALF_BYTES);
  j := 0;
  o := 0;
  for i := bytes - 1 downto 0 do
  begin
    inc(result^.Value[o], HalfUInt(data[i]) shl j);
    inc(j, 8);
    if j = HALF_BITS then
    begin
      j := 0;
      inc(o);
    end;
  end;
end;

procedure TRsaContext.SetModulo(b: PBigInt; modulo: TRsaModulo);
var
  d: HalfUInt;
  k: integer;
begin
  k := b^.Size;
  fMod[modulo] := b;
  fMod[modulo].SetPermanent;
  d := RSA_RADIX div (PtrUInt(b^.Value[k - 1]) + 1);
  fNormMod[modulo] := b.IntMultiply(d);
  fNormMod[modulo].SetPermanent;
  fMu[modulo] := fRadix.Clone.LeftShift(k * 2 - 1).Divide(fMod[modulo]);
  fMu[modulo].SetPermanent;
  fBk1[modulo] := AllocateFrom(1).LeftShift(k + 1);
  fBk1[modulo].SetPermanent;
end;

procedure TRsaContext.ResetModulo(modulo: TRsaModulo);
begin
  fMod[modulo].ResetPermanentAndRelease;
  fNormMod[modulo].ResetPermanentAndRelease;
  fMu[modulo].ResetPermanentAndRelease;
  fBk1[modulo].ResetPermanentAndRelease;
end;

function TRsaContext.Barret(b: PBigInt): PBigInt;
var
  q1, q2, q3, r1, r2, bim: PBigInt;
  k: integer;
begin
  bim := fMod[CurrentModulo];
  k := bim^.Size;
  if b^.Size > k * 2 then
  begin
    // use regular divide/modulo method instead  - Barrett cannot help
    result := b^.Divide(bim, {mod=}true);
    exit;
  end;
  // q1 = [x / b**(k-1)]
  q1 := b^.Clone.RightShift(k - 1);
  // Do outer partial multiply
  // q2 = q1 * mu
  q2 := q1.Multiply(fMu[CurrentModulo], 0, k - 1);
  // q3 = [q2 / b**(k+1)]
  q3 := q2.RightShift(k + 1);
  // r1 = x mod b**(k+1)
  r1 := b^.TruncateMod(k + 1);
  // Do inner partial multiply
  // r2 = q3 * m mod b**(k+1)
  r2 := q3.Multiply(bim, k + 1, 0).TruncateMod(k + 1);
  // if (r1 < r2) r1 = r1 + b**(k+1)
  if r1.Compare(r2) < 0 then
    r1 := r1.Add(fBk1[CurrentModulo]);
  // r = r1-r2
  result := r1.Substract(r2);
  // while (r >= m) do r = r-m
  while result.Compare(bim) >= 0 do
    result.Substract(bim);
end;



{ **************** RSA Low-Level Cryptography Functions }

end.

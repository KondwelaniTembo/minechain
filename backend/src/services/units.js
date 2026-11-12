// Weight units for reports (FR-09). Weights are stored and signed as whole milligrams
// (transactions.weight_mg, a bigint that pg returns as text), and stay text here: the
// conversion moves the decimal point in the digits, with no arithmetic, so no
// floating-point rounding can creep in. In floating point, 1234567 / 1e6 happens to print
// as 1.234567, but a large weight such as 9007199254740993 mg cannot even be held exactly
// as a JavaScript number.

// 1 kg = 1,000,000 mg, so a kilogram value needs 6 decimal places to be exact.
export const KG_DECIMALS = 6;

const WHOLE_MG = /^\d+$/;

// Milligrams to kilograms, as exact text with always 6 decimal places, for example
// '1500000' -> '1.500000' and '500' -> '0.000500'. A fixed number of decimals keeps a
// spreadsheet column aligned and shows that nothing was rounded.
// mg: whole milligrams as a string of digits (as pg returns bigint) or a bigint. A JavaScript
// number is refused, so a float can never be passed in by mistake.
export function mgToKg(mg) {
  let digits;
  if (typeof mg === 'bigint') {
    if (mg < 0n) throw new TypeError('mgToKg needs a weight of 0 or more');
    digits = mg.toString();
  } else if (typeof mg === 'string' && WHOLE_MG.test(mg)) {
    // Through BigInt only to drop leading zeros ('0001500000' -> '1500000'); the value is
    // exact at any size.
    digits = BigInt(mg).toString();
  } else {
    // The value itself is not put in the message: it could be anything a caller passed.
    throw new TypeError('mgToKg needs whole milligrams as a string of digits or a bigint');
  }

  // At least one digit before the point: '500' -> '0000500' -> '0' + '.' + '000500'.
  const padded = digits.padStart(KG_DECIMALS + 1, '0');
  return `${padded.slice(0, -KG_DECIMALS)}.${padded.slice(-KG_DECIMALS)}`;
}

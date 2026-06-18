# Masjid Al Noor Prayer Schedule Generator

Creates a prayer schedule based on the data from islamicfinder.org for the Des Moines area

---

Usage

`./generate_prayer_pdf.sh <monthNumber> [year]`

Where monthNumber is required and year is optional and will default to current year

As an example, if you want to generate the schedule for the month of June

`./generate_prayer_pdf.sh 6`

To generate June for a specific year:

`./generate_prayer_pdf.sh 6 2000`

---

Hijri month usage

`./generate_prayer_pdf_hijri.sh <hijriMonthNumber> [hijriYear]`

Where hijriMonthNumber is required and hijriYear is optional.

As an example, if you want to generate the schedule for Ramadan (month 9):

`./generate_prayer_pdf_hijri.sh 9`

To generate Ramadan for a specific Hijri year:

`./generate_prayer_pdf_hijri.sh 9 1447`

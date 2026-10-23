RGB to LAB converter

1. Put a raw-RGB CSV from ImageJ (or a whole ImageJ output folder) into
   RawRGB_input.
2. Double-click Convert.cmd.
3. The Excel workbook with corrected RGB, L*, a*, b*, Delta E (CIE76) and hue
   angle appears in output.

Works on any Windows computer: it only uses the built-in Windows PowerShell.
Copy the whole RGB_to_LAB_converter folder (including the hidden engine
folder) to use it elsewhere.

- A file named *_CONVERSION_ERROR.txt in output explains a failed conversion.
- Optional: put conversion_settings.json (see conversion_settings_example.json)
  into RawRGB_input or into an experiment folder to choose the Delta E
  reference ("reference_file" or "reference_value") or the wells to use
  ("selected_wells").
- The Delta E reference is the 0-concentration image by default, otherwise the
  lowest concentration.

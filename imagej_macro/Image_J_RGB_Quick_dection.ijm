// ============================================================================
// ImageJ/Fiji: native batch raw-RGB analysis with user-selected folders
//
// What this macro does
//   1. Ask the user to choose the source root folder.
//   2. Find every supported image directly inside that selected batch folder.
//      No file name or concentration label is required.
//   3. Stage 1: for every source image, click Black1 once.
//   4. Ask the user once to choose the output folder for THIS batch.
//   5. Stage 2: reconstruct Black2, White1, White2 and four assay wells;
//      measure raw R/G/B for the four references and 4 wells x 3 ROIs.
//   6. Save any user-selected combination of the following outputs:
//      - one raw-RGB CSV;
//      - one ROI-check PNG showing the measurement locations;
//      - four clean 60 x 60 PNG crops, one Sample1 crop per well.
//
// Important output rules
//   - Only raw measured R/G/B values are written. No white balance, corrected
//     RGB, CIELAB or Delta E values are calculated.
//   - Each ROI-check PNG is ONE copy of the source image containing every
//     reference ROI and all four wells' sampling ROIs together.
//   - Each individual well picture is the square bounding box of Sample1 only;
//     Sample2 and Sample3 are still measured for the RGB CSV but not cropped.
//   - Source images are never overwritten.
//   - Each complete ROI layout is displayed during Stage 2, then saved.
//   - The selected output folder is not fixed in the code.
//   - Source file/folder names are recorded only for traceability; they are
//     never interpreted as concentrations and never control which files run.
//
// The geometry below is calibrated for the current upright 3024 x 4032
// photographs. Every position is reconstructed relative to the Black1 point
// clicked by the user, so translation of the patch within the photograph is
// handled automatically. Same-aspect-ratio images are scaled automatically.
// ============================================================================

requires("1.53");

var MACRO_VERSION = "NativeFolderScan-2026-09-10-v12-output-checkboxes";


// ---------- RAW MEASUREMENT SETTINGS ----------
var ROI_W = 60;
var ROI_H = 60;
var SAMPLE_SPREAD = 15;
var REFERENCE_ROI_W = 60;
var REFERENCE_ROI_H = 60;
var WELL_CENTER_MARKER = 20;
var ROI_STEP_PREVIEW_MS = 60;
var COMPLETE_LAYOUT_PREVIEW_MS = 800;


// ---------- CALIBRATION GEOMETRY ----------
var CAL_W = 3024;
var CAL_H = 4032;

// Black1 is the upper-left black reference in the central 2 x 2 group.
var CAL_BLACK1_X = 1315;
var CAL_BLACK1_Y = 1940;

var CAL_BLACK2_X = 1547;
var CAL_BLACK2_Y = 2152;

var CAL_WHITE1_X = 1315;
var CAL_WHITE1_Y = 2160;

var CAL_WHITE2_X = 1547;
var CAL_WHITE2_Y = 1944;

// Order: TopLeft, BottomLeft, TopRight, BottomRight.
var CAL_WELL_X = newArray(1113, 1113, 1785, 1785);
var CAL_WELL_Y = newArray(1683, 2355, 1683, 2355);

var WELL_POSITION = newArray(
    "TopLeft", "BottomLeft", "TopRight", "BottomRight"
);

var REFERENCE_NAME = newArray(
    "Black1", "Black2", "White1", "White2"
);


// ---------- GLOBAL BATCH STATE ----------
var imagePaths = newArray(0);
var imageFileNames = newArray(0);
var imageRelativeFolders = newArray(0);
var imageOutputKeys = newArray(0);
var supportedImageCount = 0;
var scanError = "";
var scanFolderCount = 0;
var scanFileCount = 0;
var firstScannedFileName = "";
var firstScannedSupported = 0;


// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

function isSupportedSourceImage(fileName) {
    lowerName = toLowerCase(fileName);
    supported = endsWith(lowerName, ".jpg")
        || endsWith(lowerName, ".jpeg")
        || endsWith(lowerName, ".png")
        || endsWith(lowerName, ".tif")
        || endsWith(lowerName, ".tiff");

    // Never treat files produced by this macro as new source images.
    generated = endsWith(lowerName, "__roi_check.png")
        || endsWith(lowerName, "__rgb_raw_3roi.png")
        || indexOf(lowerName, "__4well_crop_locations.")>=0
        || indexOf(lowerName, "_roi_check.")>=0
        || (indexOf(lowerName, "__well")>=0
            && endsWith(lowerName, "_sample1_60x60.png"));

    return supported && !generated;
}


function makeOutputKey(relativeFolder, fileName) {
    stem = File.getNameWithoutExtension(fileName);
    return stem;
}


function makeWellCropFileName(outputKey, wellIndex) {
    return outputKey
        + "__Well" + (wellIndex+1)
        + "_" + WELL_POSITION[wellIndex]
        + "_Sample1_60x60.png";
}


function openAndOrient(path) {
    openResult = newArray(8);
    openResult[0] = 0;
    imageCountBefore = nImages;

    IJ.redirectErrorMessages();
    open(path);

    if (nImages>imageCountBefore) {
        openResult[0] = 1;
        openResult[1] = getImageID();
        openResult[2] = getWidth();
        openResult[3] = getHeight();
        openResult[6] = 0;

        if (getWidth()>getHeight()) {
            run("Rotate 90 Degrees Right");
            openResult[6] = 1;
        }

        openResult[4] = getWidth();
        openResult[5] = getHeight();
        openResult[7] = bitDepth();
    }

    return openResult;
}


function closeWithoutSaving(imageID) {
    if (isOpen(imageID)) {
        selectImage(imageID);
        setOption("Changes", false);
        close();
    }
}


function addNamedOval(cx, cy, width, height, roiName) {
    makeOval(cx-width/2, cy-height/2, width, height);
    roiManager("Add");
    currentRoiCount = roiManager("count");
    roiManager("Select", currentRoiCount-1);
    roiManager("Rename", roiName);
}


function selectBlack1(dialogTitle, messageText) {
    selectedPoint = newArray(2);
    accepted = 0;

    while (accepted==0) {
        run("Select None");
        setTool("point");
        waitForUser(dialogTitle, messageText);

        if (selectionType()!=10) {
            showMessage(
                "Black1 point required",
                "Use the Point tool and click exactly once at the CENTER "
                + "of Black1. The same image will remain open."
            );
        } else {
            getSelectionCoordinates(pointX, pointY);
            if (pointX.length!=1) {
                showMessage(
                    "One point only",
                    "Exactly one Black1 point is required."
                );
            } else {
                selectedPoint[0] = pointX[0];
                selectedPoint[1] = pointY[0];
                accepted = 1;
            }
        }
    }

    return selectedPoint;
}


function allPredictedRoisFit(black1X, black1Y, imageW, imageH) {
    scaleX = imageW/CAL_W;
    scaleY = imageH/CAL_H;
    fits = 1;

    refX = newArray(
        black1X,
        black1X + (CAL_BLACK2_X-CAL_BLACK1_X)*scaleX,
        black1X + (CAL_WHITE1_X-CAL_BLACK1_X)*scaleX,
        black1X + (CAL_WHITE2_X-CAL_BLACK1_X)*scaleX
    );
    refY = newArray(
        black1Y,
        black1Y + (CAL_BLACK2_Y-CAL_BLACK1_Y)*scaleY,
        black1Y + (CAL_WHITE1_Y-CAL_BLACK1_Y)*scaleY,
        black1Y + (CAL_WHITE2_Y-CAL_BLACK1_Y)*scaleY
    );

    for (fitIndex=0; fitIndex<4; fitIndex++) {
        if (refX[fitIndex]-REFERENCE_ROI_W/2<0
            || refY[fitIndex]-REFERENCE_ROI_H/2<0
            || refX[fitIndex]+REFERENCE_ROI_W/2>imageW
            || refY[fitIndex]+REFERENCE_ROI_H/2>imageH)
            fits = 0;
    }

    // SAMPLE_SPREAD plus half the ROI is the maximum required well margin.
    wellMarginX = SAMPLE_SPREAD + ROI_W/2;
    wellMarginY = SAMPLE_SPREAD + ROI_H/2;

    for (fitWell=0; fitWell<4; fitWell++) {
        predictedWellX = black1X
            + (CAL_WELL_X[fitWell]-CAL_BLACK1_X)*scaleX;
        predictedWellY = black1Y
            + (CAL_WELL_Y[fitWell]-CAL_BLACK1_Y)*scaleY;

        if (predictedWellX-wellMarginX<0
            || predictedWellY-wellMarginY<0
            || predictedWellX+wellMarginX>imageW
            || predictedWellY+wellMarginY>imageH)
            fits = 0;
    }

    return fits;
}


function csvQuote(value) {
    value = replace(value, "\"", "\"\"");
    return "\"" + value + "\"";
}


function folderLabel(relativeFolder) {
    result = relativeFolder;
    if (endsWith(result, "/"))
        result = substring(result, 0, lengthOf(result)-1);
    if (result=="")
        result = ".";
    return result;
}


// ============================================================================
// ADDED MODES: GLOBAL-PLAN MANUAL ROI + FULLY FLEXIBLE FALLBACK
//
// This entire block is additive. The original Black1-calibrated workflow below
// is preserved unchanged and remains selectable at startup.
//
// Recommended added workflow:
//   1. Read and list all source images first.
//   2. Define one batch-wide ROI plan: first the references, then the samples.
//      Reference size and one or more sample-size presets are entered only once.
//   3. Reuse that exact order and size plan for every image while the user
//      manually positions every ROI and clicks Selection finished.
//   4. No ROI position is predicted from Black1 or from any other ROI.
//   5. All positions are selected first; only then are images reopened and
//      measured.
//   6. Optional per-image and combined tidy raw-RGB CSV files are available.
// A separate fallback mode still permits independent size/role entry per ROI.
// ============================================================================

function manualPad3(value) {
    textValue = d2s(value, 0);
    while (lengthOf(textValue)<3)
        textValue = "0" + textValue;
    return textValue;
}


function manualSafeFilePart(value) {
    safeValue = value;
    safeValue = replace(safeValue, "\\", "_");
    safeValue = replace(safeValue, "/", "_");
    safeValue = replace(safeValue, ":", "_");
    safeValue = replace(safeValue, "*", "_");
    safeValue = replace(safeValue, "?", "_");
    safeValue = replace(safeValue, "\"", "_");
    safeValue = replace(safeValue, "<", "_");
    safeValue = replace(safeValue, ">", "_");
    safeValue = replace(safeValue, "|", "_");
    safeValue = replace(safeValue, " ", "_");
    if (safeValue=="")
        safeValue = "unnamed";
    return safeValue;
}


function manualIsSupportedSourceImage(fileName) {
    lowerName = toLowerCase(fileName);
    generatedByManualMode =
        indexOf(lowerName, "__roi_check_manualroi.")>=0
        || indexOf(lowerName, "__rgb_raw_manualroi.")>=0
        || indexOf(lowerName, "__manualroi_")>=0
        || lowerName=="batch__rgb_raw_manualroi.csv";
    return isSupportedSourceImage(fileName) && !generatedByManualMode;
}


function manualRoleCode(roleChoice) {
    if (roleChoice=="Black reference")
        return "BlackReference";
    if (roleChoice=="White reference")
        return "WhiteReference";
    return "Sample";
}


function manualRoleChoice(roleCode) {
    if (roleCode=="BlackReference")
        return "Black reference";
    if (roleCode=="WhiteReference")
        return "White reference";
    return "Sample";
}


function manualCsvHeader() {
    return "Image_Index,Source_Folder,Source_File,Condition_Field,"
        + "Condition_Unit,Condition_Value,ROI_Index,Role,Region,"
        + "Well_Position,ROI_Number,ROI_Shape,ROI_X,ROI_Y,"
        + "ROI_Width,ROI_Height,Area_px,R,G,B\n";
}


function manualRecoveryHeader() {
    return "Image_Index\tSource_Path\tSource_File\tOutput_Key\t"
        + "Condition_Field\tCondition_Unit\tCondition_Value\t"
        + "Image_Width\tImage_Height\tROI_Count\tROI_Index\tRole\t"
        + "Region\tSample_Group\tROI_Number\tROI_X\tROI_Y\t"
        + "ROI_Width\tROI_Height\n";
}


function manualTsvCell(value) {
    safeCell = replace(value, "\t", " ");
    safeCell = replace(safeCell, "\r", " ");
    safeCell = replace(safeCell, "\n", " ");
    return safeCell;
}


function manualSampleCropFileName(
    outputKey, roiIndex, groupName, regionName, roiWidth, roiHeight
) {
    return outputKey
        + "__ManualROI_" + manualPad3(roiIndex+1)
        + "_" + manualSafeFilePart(groupName)
        + "_" + manualSafeFilePart(regionName)
        + "_" + d2s(roiWidth, 0) + "x" + d2s(roiHeight, 0)
        + ".png";
}


function manualPlacePlannedOval(
    imageID, imageFile, imageIndex, imageTotal,
    roiIndex, roiTotal, roleText, groupText,
    roiWidth, roiHeight, imageWidth, imageHeight
) {
    selectedBounds = newArray(4);
    initialX = round((imageWidth-roiWidth)/2);
    initialY = round((imageHeight-roiHeight)/2);
    positionReady = 0;

    while (positionReady==0) {
        selectImage(imageID);
        makeOval(initialX, initialY, roiWidth, roiHeight);
        setTool("oval");

        if (groupText=="")
            groupLine = "";
        else
            groupLine = "\nSample group / well: " + groupText;

        waitForUser(
            "Selection finished - ROI " + (roiIndex+1)
                + "/" + roiTotal,
            "Image " + (imageIndex+1) + "/" + imageTotal
                + "\n" + imageFile + "\n\n"
                + "NEXT ROI IN THE CONFIRMED PLAN\n"
                + "Role: " + roleText + groupLine + "\n"
                + "Fixed size: " + roiWidth + " x "
                + roiHeight + " pixels\n\n"
                + "Drag this oval to the correct sampling area.\n"
                + "Do not resize it. The order is recorded exactly "
                + "as you select it.\n\n"
                + "Click OK when this ROI selection is finished."
        );

        if (selectionType()!=1) {
            showMessage(
                "Oval ROI required",
                "Keep the oval selection active, then click OK again."
            );
        } else {
            getSelectionBounds(
                selectedX, selectedY, selectedW, selectedH
            );
            if (selectedW!=roiWidth || selectedH!=roiHeight) {
                initialX = round(
                    selectedX + selectedW/2 - roiWidth/2
                );
                initialY = round(
                    selectedY + selectedH/2 - roiHeight/2
                );
                if (initialX<0)
                    initialX = 0;
                if (initialY<0)
                    initialY = 0;
                if (initialX+roiWidth>imageWidth)
                    initialX = imageWidth-roiWidth;
                if (initialY+roiHeight>imageHeight)
                    initialY = imageHeight-roiHeight;
                showMessage(
                    "ROI size changed",
                    "The planned size is " + roiWidth + " x "
                    + roiHeight + " pixels.\n\n"
                    + "The oval will be restored to that size. "
                    + "Position it again without resizing."
                );
            } else {
                selectedBounds[0] = selectedX;
                selectedBounds[1] = selectedY;
                selectedBounds[2] = selectedW;
                selectedBounds[3] = selectedH;
                positionReady = 1;
            }
        }
    }

    return selectedBounds;
}


var MANUAL_ADDED_VERSION =
    "ManualGlobalPlan-2026-09-11-v5-csv-fix-recovery";
var MANUAL_PLANNED_SIZE_MODE = 0;


function runManualFlexibleRoiWorkflow() {
    manualMaxRoisPerImage = 200;
    manualRoleChoices = newArray(
        "Black reference", "White reference", "Sample"
    );

    manualSelectedSourceRoot = getDirectory(
        "MANUAL MODE - STEP 1 of 2 - Choose the INPUT folder containing images"
    );
    if (manualSelectedSourceRoot=="")
        exit("No source folder was selected. No data were measured or saved.");

    manualSourceRoot = manualSelectedSourceRoot;
    if (!endsWith(manualSourceRoot, "/")
        && !endsWith(manualSourceRoot, "\\"))
        manualSourceRoot = manualSourceRoot + File.separator;

    manualEntryNames = getFileList(manualSourceRoot);
    manualEntryNames = Array.sort(manualEntryNames);
    manualTotalImages = 0;

    for (manualScanIndex=0;
        manualScanIndex<manualEntryNames.length;
        manualScanIndex++) {
        manualEntryName = manualEntryNames[manualScanIndex];
        manualCandidatePath = manualSourceRoot + manualEntryName;
        if (!File.isDirectory(manualCandidatePath)
            && manualIsSupportedSourceImage(manualEntryName))
            manualTotalImages++;
    }

    if (manualTotalImages==0)
        exit(
            "No supported source images were found directly inside:\n"
            + manualSourceRoot
            + "\n\nSupported formats: JPG, JPEG, PNG, TIF and TIFF."
        );

    manualImagePaths = newArray(manualTotalImages);
    manualImageFileNames = newArray(manualTotalImages);
    manualImageOutputKeys = newArray(manualTotalImages);
    manualWriteIndex = 0;

    for (manualScanIndex=0;
        manualScanIndex<manualEntryNames.length;
        manualScanIndex++) {
        manualEntryName = manualEntryNames[manualScanIndex];
        manualCandidatePath = manualSourceRoot + manualEntryName;
        if (!File.isDirectory(manualCandidatePath)
            && manualIsSupportedSourceImage(manualEntryName)) {
            manualImagePaths[manualWriteIndex] = manualCandidatePath;
            manualImageFileNames[manualWriteIndex] = manualEntryName;
            manualStem = File.getNameWithoutExtension(manualEntryName);
            manualImageOutputKeys[manualWriteIndex] =
                manualSafeFilePart(manualStem);
            manualWriteIndex++;
        }
    }

    if (MANUAL_PLANNED_SIZE_MODE) {
        Dialog.create("Planned manual ROI mode - output settings");
        Dialog.addMessage(
            "Found " + manualTotalImages + " input images.\n\n"
            + "Each image name will be read automatically and written "
            + "unchanged into the raw-RGB data. No condition mapping "
            + "will be requested.\n\n"
            + "The complete batch ROI plan will be defined once after "
            + "this dialog, then reused for every image."
        );
        Dialog.addCheckbox("Save one raw-RGB CSV per image", true);
        Dialog.addCheckbox(
            "Save one combined raw-RGB CSV for fast Excel summary", true
        );
        Dialog.addCheckbox("Save one ROI-check PNG per image", true);
        Dialog.addCheckbox(
            "Save every Sample ROI as a clean crop", true
        );
        Dialog.show();

        manualConditionField = "Image_Name";
        manualConditionUnit = "";
        manualDefaultBlackCount = 2;
        manualDefaultWhiteCount = 2;
        manualDefaultRoiW = 80;
        manualDefaultRoiH = 80;
        manualDefaultSampleGroupCount = 4;
        manualDefaultSamplePresetCount = 1;
        manualDefaultSampleReplicates = 1;
        manualDefaultSampleRoiW = 160;
        manualDefaultSampleRoiH = 160;
        manualDefaultRoiCount =
            manualDefaultBlackCount + manualDefaultWhiteCount
            + manualDefaultSampleGroupCount
                * manualDefaultSampleReplicates;
        manualSavePerImageCsv = Dialog.getCheckbox();
        manualSaveCombinedCsv = Dialog.getCheckbox();
        manualSaveRoiCheck = Dialog.getCheckbox();
        manualSaveSampleCrops = Dialog.getCheckbox();
    } else {
        Dialog.create("Fully flexible manual ROI mode - batch settings");
        Dialog.addMessage(
            "Every ROI will be positioned manually. No reference ROI will "
            + "determine another ROI.\n\n"
            + "This fallback mode can change size and role separately "
            + "for every individual ROI."
        );
        Dialog.addString(
            "Condition column name:", "Concentration", 24
        );
        Dialog.addString(
            "Condition unit (blank is allowed):", "pg/mL", 16
        );
        Dialog.addNumber("Default number of ROIs per image:", 16);
        Dialog.addNumber("Starting ROI width (pixels):", 60);
        Dialog.addNumber("Starting ROI height (pixels):", 60);
        Dialog.addNumber("Default black-reference ROI count:", 2);
        Dialog.addNumber("Default white-reference ROI count:", 2);
        Dialog.addNumber("Default sample replicates per group:", 3);
        Dialog.addCheckbox("Save one raw-RGB CSV per image", true);
        Dialog.addCheckbox(
            "Save one combined raw-RGB CSV for fast Excel summary", true
        );
        Dialog.addCheckbox("Save one ROI-check PNG per image", true);
        Dialog.addCheckbox(
            "Save every Sample ROI as a clean crop", true
        );
        Dialog.show();

        manualConditionField = Dialog.getString();
        manualConditionUnit = Dialog.getString();
        manualDefaultRoiCount = round(Dialog.getNumber());
        manualDefaultRoiW = round(Dialog.getNumber());
        manualDefaultRoiH = round(Dialog.getNumber());
        manualDefaultBlackCount = round(Dialog.getNumber());
        manualDefaultWhiteCount = round(Dialog.getNumber());
        manualDefaultSampleReplicates = round(Dialog.getNumber());
        manualDefaultSampleGroupCount = 1;
        manualDefaultSamplePresetCount = 1;
        manualDefaultSampleRoiW = manualDefaultRoiW;
        manualDefaultSampleRoiH = manualDefaultRoiH;
        manualSavePerImageCsv = Dialog.getCheckbox();
        manualSaveCombinedCsv = Dialog.getCheckbox();
        manualSaveRoiCheck = Dialog.getCheckbox();
        manualSaveSampleCrops = Dialog.getCheckbox();
    }

    if (manualConditionField=="")
        manualConditionField = "Condition";
    if (manualDefaultRoiCount<1
        || manualDefaultRoiCount>manualMaxRoisPerImage)
        exit(
            "Default ROI count must be between 1 and "
            + manualMaxRoisPerImage + "."
        );
    if (manualDefaultRoiW<1 || manualDefaultRoiH<1)
        exit("Starting ROI width and height must both be at least 1 pixel.");
    if (manualDefaultSampleRoiW<1 || manualDefaultSampleRoiH<1)
        exit("Sample ROI width and height must both be at least 1 pixel.");
    if (manualDefaultBlackCount<0 || manualDefaultWhiteCount<0)
        exit("Default reference ROI counts cannot be negative.");
    if (manualDefaultSampleGroupCount<0)
        exit("Default sample-group count cannot be negative.");
    if (manualDefaultSamplePresetCount<1
        || manualDefaultSamplePresetCount>20)
        exit("Sample ROI size-preset count must be between 1 and 20.");
    if (manualDefaultSampleReplicates<1)
        exit("Default sample replicates per group must be at least 1.");
    if (!manualSavePerImageCsv && !manualSaveCombinedCsv)
        exit(
            "Select at least one raw-RGB CSV output. "
            + "No data were measured or saved."
        );

    // Exercise the same quoted-text construction used during Stage 2 before
    // the user spends time positioning any ROI. This catches interpreter
    // string-type incompatibilities at the start instead of after Stage 1.
    manualCsvPreflightQuoted = csvQuote("ManualROI_CSV_preflight");
    manualCsvPreflightRow = "1,";
    manualCsvPreflightRow = manualCsvPreflightRow
        + manualCsvPreflightQuoted + "\n";
    if (indexOf(manualCsvPreflightRow, "ManualROI_CSV_preflight")<0)
        exit(
            "CSV text preflight failed before ROI selection. "
            + "No ROI positions were requested or changed."
        );

    // In the recommended planned mode, define ONE ROI order and size plan
    // after the complete input file list has been read. The same confirmed
    // plan is then applied to every image in the batch.
    if (MANUAL_PLANNED_SIZE_MODE) {
        manualGlobalPlanConfirmed = 0;
        while (manualGlobalPlanConfirmed==0) {
            manualPlanStructureValid = 0;
            while (manualPlanStructureValid==0) {
                Dialog.create(
                    "ONE global ROI plan - references and groups"
                );
                Dialog.addMessage(
                    "This plan is created once and reused for ALL "
                    + manualTotalImages + " images.\n\n"
                    + "Fixed selection order:\n"
                    + "1) Black references\n"
                    + "2) White references\n"
                    + "3) Sample groups / wells in the order "
                    + "you define"
                );
                Dialog.addNumber(
                    "Number of Black reference ROIs:",
                    manualDefaultBlackCount
                );
                Dialog.addNumber(
                    "Number of White reference ROIs:",
                    manualDefaultWhiteCount
                );
                Dialog.addNumber(
                    "Reference ROI width (pixels):",
                    manualDefaultRoiW
                );
                Dialog.addNumber(
                    "Reference ROI height (pixels):",
                    manualDefaultRoiH
                );
                Dialog.addNumber(
                    "Number of sample groups / wells:",
                    manualDefaultSampleGroupCount
                );
                Dialog.addNumber(
                    "Number of sample ROI size presets:",
                    manualDefaultSamplePresetCount
                );
                Dialog.addNumber(
                    "Starting sample ROI count per group:",
                    manualDefaultSampleReplicates
                );
                Dialog.addNumber(
                    "Starting sample ROI width (pixels):",
                    manualDefaultSampleRoiW
                );
                Dialog.addNumber(
                    "Starting sample ROI height (pixels):",
                    manualDefaultSampleRoiH
                );
                Dialog.show();

                manualDefaultBlackCount =
                    round(Dialog.getNumber());
                manualDefaultWhiteCount =
                    round(Dialog.getNumber());
                manualDefaultRoiW =
                    round(Dialog.getNumber());
                manualDefaultRoiH =
                    round(Dialog.getNumber());
                manualDefaultSampleGroupCount =
                    round(Dialog.getNumber());
                manualDefaultSamplePresetCount =
                    round(Dialog.getNumber());
                manualDefaultSampleReplicates =
                    round(Dialog.getNumber());
                manualDefaultSampleRoiW =
                    round(Dialog.getNumber());
                manualDefaultSampleRoiH =
                    round(Dialog.getNumber());

                if (manualDefaultBlackCount<0
                    || manualDefaultWhiteCount<0) {
                    showMessage(
                        "Invalid reference count",
                        "Reference ROI counts cannot be negative."
                    );
                } else if (manualDefaultRoiW<1
                    || manualDefaultRoiH<1) {
                    showMessage(
                        "Invalid reference ROI size",
                        "Reference ROI width and height must both "
                        + "be at least 1 pixel."
                    );
                } else if (manualDefaultSampleGroupCount<0
                    || manualDefaultSampleGroupCount>100) {
                    showMessage(
                        "Invalid sample-group count",
                        "Sample-group count must be between 0 and 100."
                    );
                } else if (manualDefaultSamplePresetCount<1
                    || manualDefaultSamplePresetCount>20) {
                    showMessage(
                        "Invalid size-preset count",
                        "Sample ROI size-preset count must be "
                        + "between 1 and 20."
                    );
                } else if (manualDefaultSampleReplicates<1) {
                    showMessage(
                        "Invalid sample ROI count",
                        "Starting sample ROI count per group must "
                        + "be at least 1."
                    );
                } else if (manualDefaultSampleRoiW<1
                    || manualDefaultSampleRoiH<1) {
                    showMessage(
                        "Invalid sample ROI size",
                        "Starting sample ROI width and height must "
                        + "both be at least 1 pixel."
                    );
                } else {
                    manualPlanStructureValid = 1;
                }
            }

            manualPresetLabels =
                newArray(manualDefaultSamplePresetCount);
            manualPresetW =
                newArray(manualDefaultSamplePresetCount);
            manualPresetH =
                newArray(manualDefaultSamplePresetCount);

            for (manualPresetIndex=0;
                manualPresetIndex<manualDefaultSamplePresetCount;
                manualPresetIndex++) {
                Dialog.create(
                    "Batch sample-size preset "
                    + (manualPresetIndex+1) + "/"
                    + manualDefaultSamplePresetCount
                );
                Dialog.addMessage(
                    "This size preset can be assigned to any number "
                    + "of sample groups / wells.\n"
                    + "It will be reused for every image in this batch."
                );
                Dialog.addString(
                    "Preset label:",
                    "SampleSize" + (manualPresetIndex+1), 22
                );
                Dialog.addNumber(
                    "ROI width (pixels):",
                    manualDefaultSampleRoiW
                );
                Dialog.addNumber(
                    "ROI height (pixels):",
                    manualDefaultSampleRoiH
                );
                Dialog.show();

                manualPresetLabels[manualPresetIndex] =
                    Dialog.getString();
                manualPresetW[manualPresetIndex] =
                    round(Dialog.getNumber());
                manualPresetH[manualPresetIndex] =
                    round(Dialog.getNumber());

                if (manualPresetLabels[manualPresetIndex]=="")
                    exit(
                        "Every sample-size preset needs a label. "
                        + "No images were measured or saved."
                    );
                if (manualPresetW[manualPresetIndex]<1
                    || manualPresetH[manualPresetIndex]<1)
                    exit(
                        "Every sample-size preset needs a positive "
                        + "width and height."
                    );
            }

            manualGroupLabels =
                newArray(manualDefaultSampleGroupCount);
            manualGroupRoiCounts =
                newArray(manualDefaultSampleGroupCount);
            manualGroupPresetIndices =
                newArray(manualDefaultSampleGroupCount);

            for (manualGroupIndex=0;
                manualGroupIndex<manualDefaultSampleGroupCount;
                manualGroupIndex++) {
                Dialog.create(
                    "Batch sample group / well "
                    + (manualGroupIndex+1) + "/"
                    + manualDefaultSampleGroupCount
                );
                Dialog.addMessage(
                    "Assign this sample group to one confirmed ROI-size "
                    + "preset.\n"
                    + "This group definition will be reused for every "
                    + "image."
                );
                Dialog.addString(
                    "Sample group / well label:",
                    "Well" + (manualGroupIndex+1), 22
                );
                Dialog.addNumber(
                    "Number of ROIs in this group:",
                    manualDefaultSampleReplicates
                );
                Dialog.addChoice(
                    "ROI-size preset:",
                    manualPresetLabels,
                    manualPresetLabels[0]
                );
                Dialog.show();

                manualGroupLabels[manualGroupIndex] =
                    Dialog.getString();
                manualGroupRoiCounts[manualGroupIndex] =
                    round(Dialog.getNumber());
                manualSelectedPresetLabel = Dialog.getChoice();

                if (manualGroupLabels[manualGroupIndex]=="")
                    exit(
                        "Every sample group / well needs a label. "
                        + "No images were measured or saved."
                    );
                if (manualGroupRoiCounts[manualGroupIndex]<1)
                    exit(
                        "Every sample group / well needs at least one ROI."
                    );

                manualGroupPresetIndices[manualGroupIndex] = 0;
                for (manualPresetIndex=0;
                    manualPresetIndex<manualDefaultSamplePresetCount;
                    manualPresetIndex++) {
                    if (manualPresetLabels[manualPresetIndex]
                        ==manualSelectedPresetLabel)
                        manualGroupPresetIndices[manualGroupIndex] =
                            manualPresetIndex;
                }
            }

            manualGlobalRoiCount =
                manualDefaultBlackCount + manualDefaultWhiteCount;
            for (manualGroupIndex=0;
                manualGroupIndex<manualDefaultSampleGroupCount;
                manualGroupIndex++)
                manualGlobalRoiCount = manualGlobalRoiCount
                    + manualGroupRoiCounts[manualGroupIndex];

            if (manualGlobalRoiCount<1
                || manualGlobalRoiCount>manualMaxRoisPerImage)
                exit(
                    "The global ROI plan contains "
                    + manualGlobalRoiCount + " ROIs.\n"
                    + "The allowed range is 1 to "
                    + manualMaxRoisPerImage + "."
                );

            manualPlanRole = newArray(manualGlobalRoiCount);
            manualPlanGroup = newArray(manualGlobalRoiCount);
            manualPlanRegion = newArray(manualGlobalRoiCount);
            manualPlanNumber = newArray(manualGlobalRoiCount);
            manualPlanW = newArray(manualGlobalRoiCount);
            manualPlanH = newArray(manualGlobalRoiCount);
            manualPlanIndex = 0;

            for (manualReferenceIndex=0;
                manualReferenceIndex<manualDefaultBlackCount;
                manualReferenceIndex++) {
                manualPlanRole[manualPlanIndex] =
                    "BlackReference";
                manualPlanGroup[manualPlanIndex] = "";
                manualPlanRegion[manualPlanIndex] =
                    "Black" + (manualReferenceIndex+1);
                manualPlanNumber[manualPlanIndex] = "";
                manualPlanW[manualPlanIndex] = manualDefaultRoiW;
                manualPlanH[manualPlanIndex] = manualDefaultRoiH;
                manualPlanIndex++;
            }

            for (manualReferenceIndex=0;
                manualReferenceIndex<manualDefaultWhiteCount;
                manualReferenceIndex++) {
                manualPlanRole[manualPlanIndex] =
                    "WhiteReference";
                manualPlanGroup[manualPlanIndex] = "";
                manualPlanRegion[manualPlanIndex] =
                    "White" + (manualReferenceIndex+1);
                manualPlanNumber[manualPlanIndex] = "";
                manualPlanW[manualPlanIndex] = manualDefaultRoiW;
                manualPlanH[manualPlanIndex] = manualDefaultRoiH;
                manualPlanIndex++;
            }

            for (manualGroupIndex=0;
                manualGroupIndex<manualDefaultSampleGroupCount;
                manualGroupIndex++) {
                manualPresetIndex =
                    manualGroupPresetIndices[manualGroupIndex];
                for (manualSampleIndex=0;
                    manualSampleIndex
                        <manualGroupRoiCounts[manualGroupIndex];
                    manualSampleIndex++) {
                    manualPlanRole[manualPlanIndex] = "Sample";
                    manualPlanGroup[manualPlanIndex] =
                        manualGroupLabels[manualGroupIndex];
                    manualPlanRegion[manualPlanIndex] =
                        "Sample" + (manualSampleIndex+1);
                    manualPlanNumber[manualPlanIndex] =
                        manualSampleIndex+1;
                    manualPlanW[manualPlanIndex] =
                        manualPresetW[manualPresetIndex];
                    manualPlanH[manualPlanIndex] =
                        manualPresetH[manualPresetIndex];
                    manualPlanIndex++;
                }
            }

            manualPlanSummary =
                "The following ONE plan will be reused for all "
                + manualTotalImages + " images.\n\n"
                + "Selection order:\n";
            for (manualPlanIndex=0;
                manualPlanIndex<manualGlobalRoiCount;
                manualPlanIndex++) {
                manualPlanSummary = manualPlanSummary
                    + (manualPlanIndex+1) + ". "
                    + manualPlanRegion[manualPlanIndex]
                    + " | " + manualPlanRole[manualPlanIndex];
                if (manualPlanRole[manualPlanIndex]=="Sample")
                    manualPlanSummary = manualPlanSummary
                        + " | " + manualPlanGroup[manualPlanIndex];
                manualPlanSummary = manualPlanSummary
                    + " | " + manualPlanW[manualPlanIndex]
                    + "x" + manualPlanH[manualPlanIndex]
                    + " px\n";
            }

            manualPlanSummary = manualPlanSummary
                + "\nInput images already found:\n";
            for (manualImageIndex=0;
                manualImageIndex<manualTotalImages;
                manualImageIndex++)
                manualPlanSummary = manualPlanSummary
                    + (manualImageIndex+1) + ". "
                    + manualImageFileNames[manualImageIndex] + "\n";

            manualGlobalPlanConfirmed = getBoolean(
                "CONFIRM ONE GLOBAL ROI PLAN\n\n"
                + manualPlanSummary + "\n"
                + "YES = use this exact order and these sizes "
                + "for every image.\n"
                + "NO = re-enter the global reference settings, "
                + "sample size presets and group assignments."
            );
        }

        manualDefaultRoiCount = manualGlobalRoiCount;
    }

    manualRoiCountByImage = newArray(manualTotalImages);
    manualWorkingWByImage = newArray(manualTotalImages);
    manualWorkingHByImage = newArray(manualTotalImages);
    manualConditionValueByImage = newArray(manualTotalImages);

    manualFlatLength = manualTotalImages*manualMaxRoisPerImage;
    manualRoiX = newArray(manualFlatLength);
    manualRoiY = newArray(manualFlatLength);
    manualRoiW = newArray(manualFlatLength);
    manualRoiH = newArray(manualFlatLength);
    manualRoiRole = newArray(manualFlatLength);
    manualRoiGroup = newArray(manualFlatLength);
    manualRoiRegion = newArray(manualFlatLength);
    manualRoiNumber = newArray(manualFlatLength);

    if (MANUAL_PLANNED_SIZE_MODE) {
        for (manualImageIndex=0;
            manualImageIndex<manualTotalImages;
            manualImageIndex++) {
            manualConditionValueByImage[manualImageIndex] =
                File.getNameWithoutExtension(
                    manualImageFileNames[manualImageIndex]
                );
        }
    }

    print("");
    print("============================================================");
    print("Added version: " + MANUAL_ADDED_VERSION);
    if (MANUAL_PLANNED_SIZE_MODE)
        print("ADDED ONE-GLOBAL-PLAN MANUAL-ROI MODE");
    else
        print("ADDED FULLY MANUAL FLEXIBLE-ROI MODE");
    print("Input: " + manualSourceRoot);
    print("Images: " + manualTotalImages);
    if (MANUAL_PLANNED_SIZE_MODE)
        print(
            "Stage 1: one confirmed batch plan; "
            + "every ROI position is manual."
        );
    else
        print(
            "Stage 1: every ROI will be manually "
            + "configured and positioned."
        );

    manualLastRoiW = manualDefaultRoiW;
    manualLastRoiH = manualDefaultRoiH;
    manualLastRoiCount = manualDefaultRoiCount;

    // ------------------------------------------------------------------------
    // MANUAL STAGE 1: SELECT AND CONFIRM EVERY ROI ON EVERY IMAGE
    // ------------------------------------------------------------------------
    for (manualImageIndex=0;
        manualImageIndex<manualTotalImages;
        manualImageIndex++) {
        showProgress(manualImageIndex, manualTotalImages);
        showStatus(
            "Manual Stage 1 [" + (manualImageIndex+1) + "/"
            + manualTotalImages + "] Opening image"
        );

        manualOpenResult =
            openAndOrient(manualImagePaths[manualImageIndex]);
        if (!manualOpenResult[0])
            exit(
                "Could not open this image:\n"
                + manualImagePaths[manualImageIndex]
                + "\n\nNo RGB data or output files were saved."
            );

        manualOriginalImageID = manualOpenResult[1];
        manualImageW = manualOpenResult[4];
        manualImageH = manualOpenResult[5];
        manualImageDepth = manualOpenResult[7];

        if (manualImageDepth!=24) {
            closeWithoutSaving(manualOriginalImageID);
            exit(
                "This source is not a 24-bit RGB image:\n"
                + manualImagePaths[manualImageIndex]
                + "\n\nConvert it to RGB first, then run the macro again."
            );
        }

        manualWorkingWByImage[manualImageIndex] = manualImageW;
        manualWorkingHByImage[manualImageIndex] = manualImageH;
        manualImageAccepted = 0;
        manualImageAttempt = 0;
        manualCurrentCondition =
            File.getNameWithoutExtension(
                manualImageFileNames[manualImageIndex]
            );
        manualCurrentRoiCount = manualLastRoiCount;

        if (MANUAL_PLANNED_SIZE_MODE) {
            manualCurrentRoiCount = manualGlobalRoiCount;
            manualRoiCountByImage[manualImageIndex] =
                manualCurrentRoiCount;
            manualCurrentCondition =
                manualConditionValueByImage[manualImageIndex];

            for (manualPlanIndex=0;
                manualPlanIndex<manualGlobalRoiCount;
                manualPlanIndex++) {
                if (manualPlanW[manualPlanIndex]>manualImageW
                    || manualPlanH[manualPlanIndex]>manualImageH) {
                    closeWithoutSaving(manualOriginalImageID);
                    exit(
                        "A planned ROI is larger than this image:\n"
                        + manualImageFileNames[manualImageIndex]
                        + "\n\nROI " + (manualPlanIndex+1)
                        + ": " + manualPlanW[manualPlanIndex]
                        + " x " + manualPlanH[manualPlanIndex]
                        + " pixels\nImage: " + manualImageW
                        + " x " + manualImageH + " pixels"
                    );
                }
            }

            while (manualImageAccepted==0) {
                manualImageAttempt++;
                selectImage(manualOriginalImageID);
                roiManager("Reset");
                Overlay.clear;
                run("Select None");

                manualClickOrder =
                    "Click exactly " + manualCurrentRoiCount
                    + " ROI CENTERS continuously in this order:\n";
                for (manualRoiIndex=0;
                    manualRoiIndex<manualCurrentRoiCount;
                    manualRoiIndex++) {
                    manualClickOrder = manualClickOrder
                        + (manualRoiIndex+1) + ". "
                        + manualPlanRegion[manualRoiIndex];
                    if (manualPlanRole[manualRoiIndex]=="Sample")
                        manualClickOrder = manualClickOrder
                            + " | "
                            + manualPlanGroup[manualRoiIndex];
                    manualClickOrder = manualClickOrder
                        + " | " + manualPlanW[manualRoiIndex]
                        + "x" + manualPlanH[manualRoiIndex]
                        + " px\n";
                }

                setTool("multipoint");
                waitForUser(
                    "Continuous ROI centers - Image "
                        + (manualImageIndex+1) + "/"
                        + manualTotalImages,
                    manualImageFileNames[manualImageIndex]
                        + "\n\n" + manualClickOrder + "\n"
                        + "Use one normal click at the CENTER of "
                        + "each reference/sample area.\n"
                        + "Do not click OK between sampling points.\n\n"
                        + "After all " + manualCurrentRoiCount
                        + " centers have been clicked, click OK once "
                        + "to finish this image and open the next image."
                );

                manualCenterSelectionValid = 1;
                manualCenterError = "";
                if (selectionType()!=10) {
                    manualCenterSelectionValid = 0;
                    manualCenterError =
                        "Use the Multi-point tool to click the ROI centers.";
                } else {
                    getSelectionCoordinates(
                        manualPointX, manualPointY
                    );
                    if (manualPointX.length
                        !=manualCurrentRoiCount) {
                        manualCenterSelectionValid = 0;
                        manualCenterError =
                            "Expected "
                            + manualCurrentRoiCount
                            + " center points, but received "
                            + manualPointX.length + ".";
                    }
                }

                if (manualCenterSelectionValid) {
                    for (manualRoiIndex=0;
                        manualRoiIndex<manualCurrentRoiCount;
                        manualRoiIndex++) {
                        manualCandidateX = round(
                            manualPointX[manualRoiIndex]
                            - manualPlanW[manualRoiIndex]/2
                        );
                        manualCandidateY = round(
                            manualPointY[manualRoiIndex]
                            - manualPlanH[manualRoiIndex]/2
                        );
                        if (manualCandidateX<0
                            || manualCandidateY<0
                            || manualCandidateX
                                + manualPlanW[manualRoiIndex]
                                >manualImageW
                            || manualCandidateY
                                + manualPlanH[manualRoiIndex]
                                >manualImageH) {
                            manualCenterSelectionValid = 0;
                            manualCenterError =
                                "Point " + (manualRoiIndex+1)
                                + " is too close to an image edge "
                                + "for its "
                                + manualPlanW[manualRoiIndex]
                                + "x"
                                + manualPlanH[manualRoiIndex]
                                + " ROI.";
                        }
                    }
                }

                if (!manualCenterSelectionValid) {
                    showMessage(
                        "Repeat this image",
                        manualCenterError + "\n\n"
                        + "All points on this image will be cleared. "
                        + "Click them again in the confirmed order."
                    );
                } else {
                    selectImage(manualOriginalImageID);
                    run("Select None");
                    setColor("yellow");
                    setFont("SansSerif", 14, "bold");

                    for (manualRoiIndex=0;
                        manualRoiIndex<manualCurrentRoiCount;
                        manualRoiIndex++) {
                        manualFlatIndex =
                            manualImageIndex*manualMaxRoisPerImage
                            + manualRoiIndex;
                        manualRoiRole[manualFlatIndex] =
                            manualPlanRole[manualRoiIndex];
                        manualRoiGroup[manualFlatIndex] =
                            manualPlanGroup[manualRoiIndex];
                        manualRoiRegion[manualFlatIndex] =
                            manualPlanRegion[manualRoiIndex];
                        manualRoiNumber[manualFlatIndex] =
                            manualPlanNumber[manualRoiIndex];
                        manualRoiW[manualFlatIndex] =
                            manualPlanW[manualRoiIndex];
                        manualRoiH[manualFlatIndex] =
                            manualPlanH[manualRoiIndex];
                        manualRoiX[manualFlatIndex] = round(
                            manualPointX[manualRoiIndex]
                            - manualRoiW[manualFlatIndex]/2
                        );
                        manualRoiY[manualFlatIndex] = round(
                            manualPointY[manualRoiIndex]
                            - manualRoiH[manualFlatIndex]/2
                        );

                        makeOval(
                            manualRoiX[manualFlatIndex],
                            manualRoiY[manualFlatIndex],
                            manualRoiW[manualFlatIndex],
                            manualRoiH[manualFlatIndex]
                        );
                        roiManager("Add");
                        manualManagerCount = roiManager("count");
                        roiManager(
                            "Select", manualManagerCount-1
                        );
                        if (manualRoiRole[manualFlatIndex]
                            =="Sample")
                            roiManager(
                                "Rename",
                                manualSafeFilePart(
                                    manualRoiGroup[manualFlatIndex]
                                )
                                + "_"
                                + manualRoiRegion[manualFlatIndex]
                            );
                        else
                            roiManager(
                                "Rename",
                                manualRoiRegion[manualFlatIndex]
                            );

                        Overlay.drawEllipse(
                            manualRoiX[manualFlatIndex],
                            manualRoiY[manualFlatIndex],
                            manualRoiW[manualFlatIndex],
                            manualRoiH[manualFlatIndex]
                        );
                        Overlay.add;
                        Overlay.drawString(
                            "" + (manualRoiIndex+1) + ":"
                            + manualRoiRegion[manualFlatIndex],
                            manualPointX[manualRoiIndex],
                            manualPointY[manualRoiIndex]
                        );
                        Overlay.add;
                    }
                    run("Select None");
                    Overlay.show;
                    wait(COMPLETE_LAYOUT_PREVIEW_MS);
                    manualImageAccepted = 1;
                }
            }
        } else {
        while (manualImageAccepted==0) {
            manualImageAttempt++;
            selectImage(manualOriginalImageID);
            roiManager("Reset");
            Overlay.clear;
            run("Select None");

            manualImageSetupValid = 0;
            while (manualImageSetupValid==0) {
                Dialog.create(
                    "Image " + (manualImageIndex+1) + "/"
                    + manualTotalImages + " - setup"
                );
                Dialog.addMessage(
                    "Source file:\n"
                    + manualImageFileNames[manualImageIndex]
                    + "\n\nConfirm the condition label and ROI count. "
                    + "The file-name text is only a starting value; "
                    + "it is not interpreted automatically."
                );
                Dialog.addString(
                    "Value for " + manualConditionField + ":",
                    manualCurrentCondition, 42
                );
                Dialog.addNumber(
                    "Number of ROIs to select on this image:",
                    manualCurrentRoiCount
                );
                Dialog.show();

                manualCurrentCondition = Dialog.getString();
                manualCurrentRoiCount = round(Dialog.getNumber());

                if (manualCurrentCondition=="") {
                    showMessage(
                        "Condition value required",
                        "Enter and confirm a condition value for this image."
                    );
                } else if (manualCurrentRoiCount<1
                    || manualCurrentRoiCount>manualMaxRoisPerImage) {
                    showMessage(
                        "ROI count out of range",
                        "The ROI count must be between 1 and "
                        + manualMaxRoisPerImage + "."
                    );
                } else {
                    manualImageSetupValid = 1;
                }
            }

            manualRoiCountByImage[manualImageIndex] =
                manualCurrentRoiCount;
            manualConditionValueByImage[manualImageIndex] =
                manualCurrentCondition;

            for (manualRoiIndex=0;
                manualRoiIndex<manualCurrentRoiCount;
                manualRoiIndex++) {
                manualFlatIndex =
                    manualImageIndex*manualMaxRoisPerImage
                    + manualRoiIndex;

                if (manualImageAttempt>1
                    && manualRoiW[manualFlatIndex]>0) {
                    manualProposedW = manualRoiW[manualFlatIndex];
                    manualProposedH = manualRoiH[manualFlatIndex];
                    manualProposedRoleChoice =
                        manualRoleChoice(
                            manualRoiRole[manualFlatIndex]
                        );
                    manualProposedGroup =
                        manualRoiGroup[manualFlatIndex];
                } else {
                    manualProposedW = manualLastRoiW;
                    manualProposedH = manualLastRoiH;

                    if (manualRoiIndex<manualDefaultBlackCount) {
                        manualProposedRoleChoice = "Black reference";
                        manualProposedGroup = "";
                    } else if (manualRoiIndex
                        <manualDefaultBlackCount
                            + manualDefaultWhiteCount) {
                        manualProposedRoleChoice = "White reference";
                        manualProposedGroup = "";
                    } else {
                        manualProposedRoleChoice = "Sample";
                        manualDefaultSampleOrdinal =
                            manualRoiIndex
                            - manualDefaultBlackCount
                            - manualDefaultWhiteCount;
                        manualDefaultGroupNumber =
                            floor(
                                manualDefaultSampleOrdinal
                                / manualDefaultSampleReplicates
                            ) + 1;
                        manualProposedGroup =
                            "Well" + manualDefaultGroupNumber;
                    }
                }

                manualRoiAccepted = 0;
                while (manualRoiAccepted==0) {
                    manualRoiSettingsValid = 0;
                    while (manualRoiSettingsValid==0) {
                        Dialog.create(
                            "Image " + (manualImageIndex+1) + "/"
                            + manualTotalImages
                            + " - ROI " + (manualRoiIndex+1) + "/"
                            + manualCurrentRoiCount
                        );
                        Dialog.addMessage(
                            "Confirm this ROI's size and role BEFORE "
                            + "positioning it.\n"
                            + "Each ROI may use a different width and height."
                        );
                        Dialog.addNumber(
                            "ROI width (pixels):", manualProposedW
                        );
                        Dialog.addNumber(
                            "ROI height (pixels):", manualProposedH
                        );
                        Dialog.addChoice(
                            "ROI role:", manualRoleChoices,
                            manualProposedRoleChoice
                        );
                        Dialog.addString(
                            "Sample group / well label "
                            + "(ignored for references):",
                            manualProposedGroup, 28
                        );
                        Dialog.show();

                        manualProposedW = round(Dialog.getNumber());
                        manualProposedH = round(Dialog.getNumber());
                        manualProposedRoleChoice = Dialog.getChoice();
                        manualProposedRoleCode =
                            manualRoleCode(manualProposedRoleChoice);
                        manualProposedGroup = Dialog.getString();

                        if (manualProposedW<1 || manualProposedH<1) {
                            showMessage(
                                "Invalid ROI size",
                                "ROI width and height must both be "
                                + "at least 1 pixel."
                            );
                        } else if (manualProposedW>manualImageW
                            || manualProposedH>manualImageH) {
                            showMessage(
                                "ROI is larger than the image",
                                "Working image size: "
                                + manualImageW + " x " + manualImageH
                                + " pixels."
                            );
                        } else if (manualProposedRoleCode=="Sample"
                            && manualProposedGroup=="") {
                            showMessage(
                                "Sample group required",
                                "Enter a well or sample-group label "
                                + "for this Sample ROI."
                            );
                        } else {
                            manualRoiSettingsValid = 1;
                        }
                    }

                    if (manualImageAttempt>1
                        && manualRoiW[manualFlatIndex]>0) {
                        manualInitialX = manualRoiX[manualFlatIndex];
                        manualInitialY = manualRoiY[manualFlatIndex];
                    } else {
                        manualInitialX =
                            round((manualImageW-manualProposedW)/2);
                        manualInitialY =
                            round((manualImageH-manualProposedH)/2);
                    }

                    if (manualInitialX<0)
                        manualInitialX = 0;
                    if (manualInitialY<0)
                        manualInitialY = 0;
                    if (manualInitialX+manualProposedW>manualImageW)
                        manualInitialX =
                            manualImageW-manualProposedW;
                    if (manualInitialY+manualProposedH>manualImageH)
                        manualInitialY =
                            manualImageH-manualProposedH;

                    manualPositionReady = 0;
                    while (manualPositionReady==0) {
                        selectImage(manualOriginalImageID);
                        makeOval(
                            manualInitialX, manualInitialY,
                            manualProposedW, manualProposedH
                        );
                        setTool("oval");
                        waitForUser(
                            "Selection finished - ROI "
                                + (manualRoiIndex+1) + "/"
                                + manualCurrentRoiCount,
                            "Image " + (manualImageIndex+1) + "/"
                                + manualTotalImages + "\n"
                                + manualImageFileNames[manualImageIndex]
                                + "\n\nDrag this "
                                + manualProposedW + " x "
                                + manualProposedH
                                + " oval to the required sampling area.\n"
                                + "Do not resize it.\n\n"
                                + "Click OK when this ROI selection "
                                + "is finished."
                        );

                        if (selectionType()!=1) {
                            showMessage(
                                "Oval ROI required",
                                "Keep the oval selection active, "
                                + "then click OK again."
                            );
                        } else {
                            getSelectionBounds(
                                manualSelectedX, manualSelectedY,
                                manualSelectedW, manualSelectedH
                            );

                            if (manualSelectedW!=manualProposedW
                                || manualSelectedH!=manualProposedH) {
                                manualInitialX = round(
                                    manualSelectedX
                                    + manualSelectedW/2
                                    - manualProposedW/2
                                );
                                manualInitialY = round(
                                    manualSelectedY
                                    + manualSelectedH/2
                                    - manualProposedH/2
                                );
                                if (manualInitialX<0)
                                    manualInitialX = 0;
                                if (manualInitialY<0)
                                    manualInitialY = 0;
                                if (manualInitialX
                                    + manualProposedW>manualImageW)
                                    manualInitialX =
                                        manualImageW-manualProposedW;
                                if (manualInitialY
                                    + manualProposedH>manualImageH)
                                    manualInitialY =
                                        manualImageH-manualProposedH;
                                showMessage(
                                    "ROI size changed",
                                    "The ROI was resized to "
                                    + manualSelectedW + " x "
                                    + manualSelectedH + " pixels.\n\n"
                                    + "It will be restored to the "
                                    + "confirmed size "
                                    + manualProposedW + " x "
                                    + manualProposedH
                                    + ". Position it again without "
                                    + "resizing."
                                );
                            } else {
                                manualPositionReady = 1;
                            }
                        }
                    }

                    if (manualProposedRoleCode=="Sample")
                        manualRoleLine =
                            manualProposedRoleChoice
                            + "\nSample group / well: "
                            + manualProposedGroup;
                    else
                        manualRoleLine = manualProposedRoleChoice;

                    manualRoiAccepted = getBoolean(
                        "Confirm ROI " + (manualRoiIndex+1)
                        + " of " + manualCurrentRoiCount + "\n\n"
                        + "Role: " + manualRoleLine + "\n"
                        + "Size: " + manualSelectedW + " x "
                        + manualSelectedH + " pixels\n"
                        + "Top-left position: X=" + manualSelectedX
                        + ", Y=" + manualSelectedY + "\n\n"
                        + "YES = accept this ROI.\n"
                        + "NO = change its size, role or position."
                    );

                    if (manualRoiAccepted) {
                        manualRoiX[manualFlatIndex] =
                            manualSelectedX;
                        manualRoiY[manualFlatIndex] =
                            manualSelectedY;
                        manualRoiW[manualFlatIndex] =
                            manualSelectedW;
                        manualRoiH[manualFlatIndex] =
                            manualSelectedH;
                        manualRoiRole[manualFlatIndex] =
                            manualProposedRoleCode;
                        if (manualProposedRoleCode=="Sample")
                            manualRoiGroup[manualFlatIndex] =
                                manualProposedGroup;
                        else
                            manualRoiGroup[manualFlatIndex] = "";

                        roiManager("Add");
                        manualManagerCount = roiManager("count");
                        roiManager("Select", manualManagerCount-1);
                        roiManager(
                            "Rename",
                            "ROI_" + manualPad3(manualRoiIndex+1)
                        );

                        setColor("yellow");
                        Overlay.drawEllipse(
                            manualSelectedX, manualSelectedY,
                            manualSelectedW, manualSelectedH
                        );
                        Overlay.add;
                        Overlay.drawString(
                            "" + (manualRoiIndex+1),
                            manualSelectedX + manualSelectedW/2,
                            manualSelectedY + manualSelectedH/2
                        );
                        Overlay.add;
                        Overlay.show;

                        manualLastRoiW = manualSelectedW;
                        manualLastRoiH = manualSelectedH;
                    } else {
                        manualInitialX = manualSelectedX;
                        manualInitialY = manualSelectedY;
                    }
                }
            }

            manualBlackNumber = 0;
            manualWhiteNumber = 0;
            manualRoleSummary =
                "Image: " + manualImageFileNames[manualImageIndex]
                + "\n" + manualConditionField + ": "
                + manualCurrentCondition;

            for (manualRoiIndex=0;
                manualRoiIndex<manualCurrentRoiCount;
                manualRoiIndex++) {
                manualFlatIndex =
                    manualImageIndex*manualMaxRoisPerImage
                    + manualRoiIndex;
                manualCurrentRole =
                    manualRoiRole[manualFlatIndex];

                if (manualCurrentRole=="BlackReference") {
                    manualBlackNumber++;
                    manualRoiRegion[manualFlatIndex] =
                        "Black" + manualBlackNumber;
                    manualRoiNumber[manualFlatIndex] = "";
                } else if (manualCurrentRole=="WhiteReference") {
                    manualWhiteNumber++;
                    manualRoiRegion[manualFlatIndex] =
                        "White" + manualWhiteNumber;
                    manualRoiNumber[manualFlatIndex] = "";
                } else {
                    manualSampleNumber = 1;
                    for (manualPreviousRoi=0;
                        manualPreviousRoi<manualRoiIndex;
                        manualPreviousRoi++) {
                        manualPreviousFlat =
                            manualImageIndex*manualMaxRoisPerImage
                            + manualPreviousRoi;
                        if (manualRoiRole[manualPreviousFlat]
                                =="Sample"
                            && manualRoiGroup[manualPreviousFlat]
                                ==manualRoiGroup[manualFlatIndex])
                            manualSampleNumber++;
                    }
                    manualRoiRegion[manualFlatIndex] =
                        "Sample" + manualSampleNumber;
                    manualRoiNumber[manualFlatIndex] =
                        manualSampleNumber;
                }

                manualRoleSummary = manualRoleSummary
                    + "\n" + (manualRoiIndex+1) + ". "
                    + manualRoiRegion[manualFlatIndex]
                    + " | " + manualRoiRole[manualFlatIndex];
                if (manualCurrentRole=="Sample")
                    manualRoleSummary = manualRoleSummary
                        + " | " + manualRoiGroup[manualFlatIndex];
                manualRoleSummary = manualRoleSummary
                    + " | " + manualRoiW[manualFlatIndex]
                    + "x" + manualRoiH[manualFlatIndex]
                    + " px";

                roiManager("Select", manualRoiIndex);
                if (manualCurrentRole=="Sample")
                    roiManager(
                        "Rename",
                        manualSafeFilePart(
                            manualRoiGroup[manualFlatIndex]
                        )
                        + "_" + manualRoiRegion[manualFlatIndex]
                    );
                else
                    roiManager(
                        "Rename",
                        manualRoiRegion[manualFlatIndex]
                    );
            }

            selectImage(manualOriginalImageID);
            run("Select None");
            Overlay.clear;
            setColor("yellow");
            setFont("SansSerif", 14, "bold");
            for (manualRoiIndex=0;
                manualRoiIndex<manualCurrentRoiCount;
                manualRoiIndex++) {
                manualFlatIndex =
                    manualImageIndex*manualMaxRoisPerImage
                    + manualRoiIndex;
                Overlay.drawEllipse(
                    manualRoiX[manualFlatIndex],
                    manualRoiY[manualFlatIndex],
                    manualRoiW[manualFlatIndex],
                    manualRoiH[manualFlatIndex]
                );
                Overlay.add;
                Overlay.drawString(
                    "" + (manualRoiIndex+1) + ":"
                    + manualRoiRegion[manualFlatIndex],
                    manualRoiX[manualFlatIndex]
                        + manualRoiW[manualFlatIndex]/2,
                    manualRoiY[manualFlatIndex]
                        + manualRoiH[manualFlatIndex]/2
                );
                Overlay.add;
            }
            Overlay.show;

            if (manualBlackNumber==0 || manualWhiteNumber==0)
                manualRoleSummary = manualRoleSummary
                    + "\n\nWARNING: this image has "
                    + manualBlackNumber + " black reference(s) and "
                    + manualWhiteNumber + " white reference(s). "
                    + "Raw RGB can still be saved, but later reference "
                    + "correction may be impossible.";

            manualImageAccepted = getBoolean(
                "FINAL IMAGE CONFIRMATION - "
                + (manualImageIndex+1) + "/"
                + manualTotalImages + "\n\n"
                + manualRoleSummary + "\n\n"
                + "YES = all positions, sizes and roles are correct.\n"
                + "NO = redo this image before continuing."
            );

            if (!manualImageAccepted) {
                roiManager("Reset");
                Overlay.clear;
                run("Select None");
            }
        }
        }

        manualLastRoiCount = manualCurrentRoiCount;
        print(
            "CONFIRMED Stage 1 [" + (manualImageIndex+1) + "/"
            + manualTotalImages + "]: "
            + manualImageFileNames[manualImageIndex]
        );
        closeWithoutSaving(manualOriginalImageID);
        roiManager("Reset");
    }

    showProgress(1, 1);
    manualBatchRoleSummary =
        "All images have completed manual ROI selection.\n\n";
    for (manualImageIndex=0;
        manualImageIndex<manualTotalImages;
        manualImageIndex++) {
        manualBatchBlack = 0;
        manualBatchWhite = 0;
        manualBatchSample = 0;
        for (manualRoiIndex=0;
            manualRoiIndex
                <manualRoiCountByImage[manualImageIndex];
            manualRoiIndex++) {
            manualFlatIndex =
                manualImageIndex*manualMaxRoisPerImage
                + manualRoiIndex;
            if (manualRoiRole[manualFlatIndex]
                =="BlackReference")
                manualBatchBlack++;
            else if (manualRoiRole[manualFlatIndex]
                =="WhiteReference")
                manualBatchWhite++;
            else
                manualBatchSample++;
        }

        manualBatchRoleSummary = manualBatchRoleSummary
            + (manualImageIndex+1) + ". "
            + manualImageFileNames[manualImageIndex]
            + "\n   " + manualConditionField + "="
            + manualConditionValueByImage[manualImageIndex]
            + " | Black=" + manualBatchBlack
            + ", White=" + manualBatchWhite
            + ", Sample=" + manualBatchSample + "\n";
    }

    manualBatchConfirmed = getBoolean(
        "FINAL BATCH ROLE CONFIRMATION\n\n"
        + manualBatchRoleSummary + "\n"
        + "YES = roles are correct; proceed to output and RGB measurement.\n"
        + "NO = stop now. No RGB data or output files will be saved."
    );
    if (!manualBatchConfirmed)
        exit(
            "Stopped before measurement and saving. "
            + "No RGB data or output files were saved."
        );

    // ------------------------------------------------------------------------
    // OUTPUT SELECTION OCCURS ONLY AFTER EVERY IMAGE HAS BEEN CONFIRMED
    // ------------------------------------------------------------------------
    manualSelectedOutputDir = getDirectory(
        "MANUAL MODE - STEP 2 of 2 - Choose the OUTPUT folder"
    );
    if (manualSelectedOutputDir=="")
        exit(
            "No output folder was selected. "
            + "No RGB data or output files were saved."
        );
    manualOutputDir = manualSelectedOutputDir;
    if (!endsWith(manualOutputDir, "/")
        && !endsWith(manualOutputDir, "\\"))
        manualOutputDir = manualOutputDir + File.separator;

    manualWriteTestPath = manualOutputDir
        + "__ManualROI_Output_Write_Test_"
        + d2s(getTime(), 0) + ".tmp";
    File.saveString("OK", manualWriteTestPath);
    if (!File.exists(manualWriteTestPath)
        || File.length(manualWriteTestPath)==0)
        exit(
            "The selected output folder is not writable:\n"
            + manualOutputDir
        );
    File.delete(manualWriteTestPath);

    manualCombinedCsvPath =
        manualOutputDir + "Batch__RGB_Raw_ManualROI.csv";
    manualExistingOutputCount = 0;
    if (manualSaveCombinedCsv
        && File.exists(manualCombinedCsvPath))
        manualExistingOutputCount++;

    for (manualImageIndex=0;
        manualImageIndex<manualTotalImages;
        manualImageIndex++) {
        manualOutputKey =
            manualImageOutputKeys[manualImageIndex];
        manualPerImageCsvPath = manualOutputDir
            + manualOutputKey + "__RGB_Raw_ManualROI.csv";
        manualQcPath = manualOutputDir
            + manualOutputKey + "__ROI_Check_ManualROI.png";

        if (manualSavePerImageCsv
            && File.exists(manualPerImageCsvPath))
            manualExistingOutputCount++;
        if (manualSaveRoiCheck && File.exists(manualQcPath))
            manualExistingOutputCount++;

        if (manualSaveSampleCrops) {
            for (manualRoiIndex=0;
                manualRoiIndex
                    <manualRoiCountByImage[manualImageIndex];
                manualRoiIndex++) {
                manualFlatIndex =
                    manualImageIndex*manualMaxRoisPerImage
                    + manualRoiIndex;
                if (manualRoiRole[manualFlatIndex]=="Sample") {
                    manualCropPath = manualOutputDir
                        + manualSampleCropFileName(
                            manualOutputKey,
                            manualRoiIndex,
                            manualRoiGroup[manualFlatIndex],
                            manualRoiRegion[manualFlatIndex],
                            manualRoiW[manualFlatIndex],
                            manualRoiH[manualFlatIndex]
                        );
                    if (File.exists(manualCropPath))
                        manualExistingOutputCount++;
                }
            }
        }
    }

    if (manualExistingOutputCount>0) {
        manualOverwriteExisting = getBoolean(
            manualExistingOutputCount
            + " selected output file(s) already exist in:\n"
            + manualOutputDir + "\n\n"
            + "YES = replace only those matching manual-mode outputs.\n"
            + "NO = stop without measuring or saving."
        );
        if (!manualOverwriteExisting)
            exit("Existing outputs were kept. No new files were saved.");

        manualDeleteFailureCount = 0;
        if (manualSaveCombinedCsv
            && File.exists(manualCombinedCsvPath)) {
            File.delete(manualCombinedCsvPath);
            if (File.exists(manualCombinedCsvPath))
                manualDeleteFailureCount++;
        }

        for (manualImageIndex=0;
            manualImageIndex<manualTotalImages;
            manualImageIndex++) {
            manualOutputKey =
                manualImageOutputKeys[manualImageIndex];
            manualPerImageCsvPath = manualOutputDir
                + manualOutputKey + "__RGB_Raw_ManualROI.csv";
            manualQcPath = manualOutputDir
                + manualOutputKey + "__ROI_Check_ManualROI.png";

            if (manualSavePerImageCsv
                && File.exists(manualPerImageCsvPath)) {
                File.delete(manualPerImageCsvPath);
                if (File.exists(manualPerImageCsvPath))
                    manualDeleteFailureCount++;
            }
            if (manualSaveRoiCheck
                && File.exists(manualQcPath)) {
                File.delete(manualQcPath);
                if (File.exists(manualQcPath))
                    manualDeleteFailureCount++;
            }

            if (manualSaveSampleCrops) {
                for (manualRoiIndex=0;
                    manualRoiIndex
                        <manualRoiCountByImage[manualImageIndex];
                    manualRoiIndex++) {
                    manualFlatIndex =
                        manualImageIndex*manualMaxRoisPerImage
                        + manualRoiIndex;
                    if (manualRoiRole[manualFlatIndex]=="Sample") {
                        manualCropPath = manualOutputDir
                            + manualSampleCropFileName(
                                manualOutputKey,
                                manualRoiIndex,
                                manualRoiGroup[manualFlatIndex],
                                manualRoiRegion[manualFlatIndex],
                                manualRoiW[manualFlatIndex],
                                manualRoiH[manualFlatIndex]
                            );
                        if (File.exists(manualCropPath)) {
                            File.delete(manualCropPath);
                            if (File.exists(manualCropPath))
                                manualDeleteFailureCount++;
                        }
                    }
                }
            }
        }

        if (manualDeleteFailureCount>0)
            exit(
                "Could not replace "
                + manualDeleteFailureCount
                + " existing output file(s).\n"
                + "Close those files in other programs and run again."
            );
    }

    // Save every confirmed Stage-1 coordinate before Stage 2 starts. The
    // temporary recovery file is removed only after a completely successful
    // batch; if measurement is interrupted, the user's manual work remains on
    // disk for recovery instead of existing only in interpreter memory.
    manualRecoveryPath = manualOutputDir
        + "__ManualROI_Stage1_Recovery.tsv";
    manualRecoveryText = manualRecoveryHeader();
    for (manualRecoveryImageIndex=0;
        manualRecoveryImageIndex<manualTotalImages;
        manualRecoveryImageIndex++) {
        manualRecoverySourcePath = manualTsvCell(
            manualImagePaths[manualRecoveryImageIndex]
        );
        manualRecoverySourceFile = manualTsvCell(
            manualImageFileNames[manualRecoveryImageIndex]
        );
        manualRecoveryOutputKey = manualTsvCell(
            manualImageOutputKeys[manualRecoveryImageIndex]
        );
        manualRecoveryConditionField = manualTsvCell(
            manualConditionField
        );
        manualRecoveryConditionUnit = manualTsvCell(
            manualConditionUnit
        );
        manualRecoveryConditionValue = manualTsvCell(
            manualConditionValueByImage[manualRecoveryImageIndex]
        );

        for (manualRecoveryRoiIndex=0;
            manualRecoveryRoiIndex
                <manualRoiCountByImage[manualRecoveryImageIndex];
            manualRecoveryRoiIndex++) {
            manualRecoveryFlatIndex =
                manualRecoveryImageIndex*manualMaxRoisPerImage
                + manualRecoveryRoiIndex;
            manualRecoveryRole = manualTsvCell(
                manualRoiRole[manualRecoveryFlatIndex]
            );
            manualRecoveryRegion = manualTsvCell(
                manualRoiRegion[manualRecoveryFlatIndex]
            );
            manualRecoveryGroup = manualTsvCell(
                manualRoiGroup[manualRecoveryFlatIndex]
            );
            manualRecoveryLine = "";
            manualRecoveryLine = manualRecoveryLine
                + d2s(manualRecoveryImageIndex+1, 0) + "\t"
                + manualRecoverySourcePath + "\t"
                + manualRecoverySourceFile + "\t"
                + manualRecoveryOutputKey + "\t"
                + manualRecoveryConditionField + "\t"
                + manualRecoveryConditionUnit + "\t"
                + manualRecoveryConditionValue + "\t"
                + d2s(
                    manualWorkingWByImage[manualRecoveryImageIndex], 0
                ) + "\t"
                + d2s(
                    manualWorkingHByImage[manualRecoveryImageIndex], 0
                ) + "\t"
                + d2s(
                    manualRoiCountByImage[manualRecoveryImageIndex], 0
                ) + "\t"
                + d2s(manualRecoveryRoiIndex+1, 0) + "\t"
                + manualRecoveryRole + "\t"
                + manualRecoveryRegion + "\t"
                + manualRecoveryGroup + "\t"
                + manualRoiNumber[manualRecoveryFlatIndex] + "\t"
                + d2s(manualRoiX[manualRecoveryFlatIndex], 0) + "\t"
                + d2s(manualRoiY[manualRecoveryFlatIndex], 0) + "\t"
                + d2s(manualRoiW[manualRecoveryFlatIndex], 0) + "\t"
                + d2s(manualRoiH[manualRecoveryFlatIndex], 0) + "\n";
            manualRecoveryText = manualRecoveryText
                + manualRecoveryLine;
        }
    }
    File.saveString(manualRecoveryText, manualRecoveryPath);
    if (!File.exists(manualRecoveryPath)
        || File.length(manualRecoveryPath)==0)
        exit(
            "Could not save the Stage-1 ROI recovery file:\n"
            + manualRecoveryPath
            + "\n\nStage 2 was not started, so the open run can be "
            + "checked without producing partial measurements."
        );
    print("Stage-1 ROI recovery saved: " + manualRecoveryPath);

    // ------------------------------------------------------------------------
    // MANUAL STAGE 2: REOPEN, RECONSTRUCT, MEASURE AND SAVE
    // ------------------------------------------------------------------------
    print("Stage 2: reconstructing confirmed ROIs and measuring raw RGB.");
    manualCombinedCsvText = manualCsvHeader();
    manualProcessedCount = 0;
    manualStage2ErrorCount = 0;

    for (manualImageIndex=0;
        manualImageIndex<manualTotalImages;
        manualImageIndex++) {
        showProgress(manualImageIndex, manualTotalImages);
        showStatus(
            "Manual Stage 2 [" + (manualImageIndex+1) + "/"
            + manualTotalImages + "] Measuring raw RGB"
        );

        manualImagePath =
            manualImagePaths[manualImageIndex];
        manualSourceFile =
            manualImageFileNames[manualImageIndex];
        manualOutputKey =
            manualImageOutputKeys[manualImageIndex];
        manualPerImageCsvPath = manualOutputDir
            + manualOutputKey + "__RGB_Raw_ManualROI.csv";
        manualQcPath = manualOutputDir
            + manualOutputKey + "__ROI_Check_ManualROI.png";

        manualOpenResult = openAndOrient(manualImagePath);
        if (!manualOpenResult[0]) {
            manualStage2ErrorCount++;
            print("SKIPPED Stage 2 open failed: " + manualImagePath);
        } else {
            manualOriginalImageID = manualOpenResult[1];
            manualImageW = manualOpenResult[4];
            manualImageH = manualOpenResult[5];
            manualImageDepth = manualOpenResult[7];

            if (manualImageDepth!=24
                || manualImageW
                    !=manualWorkingWByImage[manualImageIndex]
                || manualImageH
                    !=manualWorkingHByImage[manualImageIndex]) {
                manualStage2ErrorCount++;
                print(
                    "SKIPPED image changed after manual Stage 1: "
                    + manualImagePath
                );
                closeWithoutSaving(manualOriginalImageID);
            } else {
                selectImage(manualOriginalImageID);
                roiManager("Reset");
                Overlay.clear;
                run("Select None");
                setColor("yellow");
                setFont("SansSerif", 14, "bold");

                for (manualRoiIndex=0;
                    manualRoiIndex
                        <manualRoiCountByImage[manualImageIndex];
                    manualRoiIndex++) {
                    manualFlatIndex =
                        manualImageIndex*manualMaxRoisPerImage
                        + manualRoiIndex;
                    makeOval(
                        manualRoiX[manualFlatIndex],
                        manualRoiY[manualFlatIndex],
                        manualRoiW[manualFlatIndex],
                        manualRoiH[manualFlatIndex]
                    );
                    roiManager("Add");
                    manualManagerCount = roiManager("count");
                    roiManager("Select", manualManagerCount-1);
                    if (manualRoiRole[manualFlatIndex]=="Sample")
                        roiManager(
                            "Rename",
                            manualSafeFilePart(
                                manualRoiGroup[manualFlatIndex]
                            )
                            + "_" + manualRoiRegion[manualFlatIndex]
                        );
                    else
                        roiManager(
                            "Rename",
                            manualRoiRegion[manualFlatIndex]
                        );

                    Overlay.drawEllipse(
                        manualRoiX[manualFlatIndex],
                        manualRoiY[manualFlatIndex],
                        manualRoiW[manualFlatIndex],
                        manualRoiH[manualFlatIndex]
                    );
                    Overlay.add;
                    Overlay.drawString(
                        "" + (manualRoiIndex+1) + ":"
                        + manualRoiRegion[manualFlatIndex],
                        manualRoiX[manualFlatIndex]
                            + manualRoiW[manualFlatIndex]/2,
                        manualRoiY[manualFlatIndex]
                            + manualRoiH[manualFlatIndex]/2
                    );
                    Overlay.add;
                }
                Overlay.show;

                if (manualSaveSampleCrops) {
                    for (manualRoiIndex=0;
                        manualRoiIndex
                            <manualRoiCountByImage[manualImageIndex];
                        manualRoiIndex++) {
                        manualFlatIndex =
                            manualImageIndex*manualMaxRoisPerImage
                            + manualRoiIndex;
                        if (manualRoiRole[manualFlatIndex]=="Sample") {
                            selectImage(manualOriginalImageID);
                            roiManager("Select", manualRoiIndex);
                            getSelectionBounds(
                                manualCropX, manualCropY,
                                manualCropW, manualCropH
                            );
                            makeRectangle(
                                manualCropX, manualCropY,
                                manualCropW, manualCropH
                            );
                            run(
                                "Duplicate...",
                                "title=__ManualROI_Crop_"
                                    + (manualRoiIndex+1)
                            );
                            manualCropImageID = getImageID();
                            selectImage(manualCropImageID);
                            Overlay.clear;
                            run("Select None");
                            manualCropPath = manualOutputDir
                                + manualSampleCropFileName(
                                    manualOutputKey,
                                    manualRoiIndex,
                                    manualRoiGroup[manualFlatIndex],
                                    manualRoiRegion[manualFlatIndex],
                                    manualRoiW[manualFlatIndex],
                                    manualRoiH[manualFlatIndex]
                                );
                            saveAs("PNG", manualCropPath);
                            closeWithoutSaving(manualCropImageID);
                        }
                    }
                }

                // Keep the proven safeguard: no active selection before
                // flattening the full-image ROI-check overlay.
                selectImage(manualOriginalImageID);
                run("Select None");
                if (manualSaveRoiCheck) {
                    run("Flatten");
                    manualQcImageID = getImageID();
                    saveAs("PNG", manualQcPath);
                    closeWithoutSaving(manualQcImageID);
                }

                selectImage(manualOriginalImageID);
                run("Select None");
                run(
                    "Duplicate...",
                    "title=__ManualROI_RGB_measurement_"
                        + (manualImageIndex+1)
                );
                manualMeasurementImageID = getImageID();
                Overlay.clear;
                run("RGB Stack");

                manualPerImageCsvText = manualCsvHeader();
                for (manualRoiIndex=0;
                    manualRoiIndex
                        <manualRoiCountByImage[manualImageIndex];
                    manualRoiIndex++) {
                    manualFlatIndex =
                        manualImageIndex*manualMaxRoisPerImage
                        + manualRoiIndex;
                    roiManager("Select", manualRoiIndex);

                    setSlice(1);
                    getStatistics(
                        manualAreaPixels, manualMeanR,
                        manualMinValue, manualMaxValue,
                        manualChannelSD
                    );
                    setSlice(2);
                    getStatistics(
                        manualAreaUnused, manualMeanG,
                        manualMinValue, manualMaxValue,
                        manualChannelSD
                    );
                    setSlice(3);
                    getStatistics(
                        manualAreaUnused, manualMeanB,
                        manualMinValue, manualMaxValue,
                        manualChannelSD
                    );

                    if (manualRoiRole[manualFlatIndex]=="Sample") {
                        manualWellField =
                            manualRoiGroup[manualFlatIndex];
                        manualNumberField =
                            manualRoiNumber[manualFlatIndex];
                    } else {
                        manualWellField = "";
                        manualNumberField = "";
                    }

                    manualQuotedSourceFolder = csvQuote(".");
                    manualQuotedSourceFile =
                        csvQuote(manualSourceFile);
                    manualQuotedConditionField =
                        csvQuote(manualConditionField);
                    manualQuotedConditionUnit =
                        csvQuote(manualConditionUnit);
                    manualQuotedConditionValue = csvQuote(
                        manualConditionValueByImage[
                            manualImageIndex
                        ]
                    );
                    manualQuotedRole = csvQuote(
                        manualRoiRole[manualFlatIndex]
                    );
                    manualQuotedRegion = csvQuote(
                        manualRoiRegion[manualFlatIndex]
                    );
                    manualQuotedWell =
                        csvQuote(manualWellField);

                    // Start explicitly with text. Older ImageJ interpreters
                    // can treat a long expression beginning with a number as
                    // numeric and then reject a string-returning function.
                    manualCsvRow =
                        d2s(manualImageIndex+1, 0) + ",";
                    manualCsvRow = manualCsvRow
                        + manualQuotedSourceFolder + ","
                        + manualQuotedSourceFile + ","
                        + manualQuotedConditionField + ","
                        + manualQuotedConditionUnit + ","
                        + manualQuotedConditionValue + ","
                        + d2s(manualRoiIndex+1, 0) + ","
                        + manualQuotedRole + ","
                        + manualQuotedRegion + ","
                        + manualQuotedWell + ","
                        + manualNumberField + ","
                        + "Oval,"
                        + d2s(manualRoiX[manualFlatIndex], 0) + ","
                        + d2s(manualRoiY[manualFlatIndex], 0) + ","
                        + d2s(manualRoiW[manualFlatIndex], 0) + ","
                        + d2s(manualRoiH[manualFlatIndex], 0) + ","
                        + d2s(manualAreaPixels, 3) + ","
                        + d2s(manualMeanR, 3) + ","
                        + d2s(manualMeanG, 3) + ","
                        + d2s(manualMeanB, 3) + "\n";

                    manualPerImageCsvText =
                        manualPerImageCsvText + manualCsvRow;
                    if (manualSaveCombinedCsv)
                        manualCombinedCsvText =
                            manualCombinedCsvText + manualCsvRow;
                }

                if (manualSavePerImageCsv)
                    File.saveString(
                        manualPerImageCsvText,
                        manualPerImageCsvPath
                    );

                closeWithoutSaving(manualMeasurementImageID);
                closeWithoutSaving(manualOriginalImageID);
                roiManager("Reset");

                manualImageOutputsOk = 1;
                if (manualSavePerImageCsv
                    && (!File.exists(manualPerImageCsvPath)
                        || File.length(manualPerImageCsvPath)==0))
                    manualImageOutputsOk = 0;
                if (manualSaveRoiCheck
                    && (!File.exists(manualQcPath)
                        || File.length(manualQcPath)==0))
                    manualImageOutputsOk = 0;
                if (manualSaveSampleCrops) {
                    for (manualRoiIndex=0;
                        manualRoiIndex
                            <manualRoiCountByImage[manualImageIndex];
                        manualRoiIndex++) {
                        manualFlatIndex =
                            manualImageIndex*manualMaxRoisPerImage
                            + manualRoiIndex;
                        if (manualRoiRole[manualFlatIndex]=="Sample") {
                            manualCropPath = manualOutputDir
                                + manualSampleCropFileName(
                                    manualOutputKey,
                                    manualRoiIndex,
                                    manualRoiGroup[manualFlatIndex],
                                    manualRoiRegion[manualFlatIndex],
                                    manualRoiW[manualFlatIndex],
                                    manualRoiH[manualFlatIndex]
                                );
                            if (!File.exists(manualCropPath)
                                || File.length(manualCropPath)==0)
                                manualImageOutputsOk = 0;
                        }
                    }
                }

                if (manualImageOutputsOk) {
                    manualProcessedCount++;
                    print(
                        "SAVED Manual Stage 2 ["
                        + (manualImageIndex+1) + "/"
                        + manualTotalImages + "]: "
                        + manualSourceFile
                    );
                } else {
                    manualStage2ErrorCount++;
                    print(
                        "SAVE FAILED Manual Stage 2: "
                        + manualImagePath
                    );
                }
            }
        }
    }

    if (manualSaveCombinedCsv)
        File.saveString(
            manualCombinedCsvText, manualCombinedCsvPath
        );

    manualCombinedOk = 1;
    if (manualSaveCombinedCsv
        && (!File.exists(manualCombinedCsvPath)
            || File.length(manualCombinedCsvPath)==0))
        manualCombinedOk = 0;

    if (!manualCombinedOk)
        manualStage2ErrorCount++;

    if (manualStage2ErrorCount==0
        && manualProcessedCount==manualTotalImages) {
        File.delete(manualRecoveryPath);
        if (File.exists(manualRecoveryPath))
            print(
                "WARNING: completed successfully, but could not delete "
                + "the temporary ROI recovery file: "
                + manualRecoveryPath
            );
        else
            print(
                "Stage-1 ROI recovery removed after successful completion."
            );
    } else {
        print(
            "Stage-1 ROI recovery kept because the batch was incomplete: "
            + manualRecoveryPath
        );
    }

    showProgress(1, 1);
    showStatus("Fully manual flexible-ROI batch finished.");

    manualSavedDescription = "";
    if (manualSavePerImageCsv)
        manualSavedDescription = manualSavedDescription
            + "\n- one raw-RGB CSV per image";
    if (manualSaveCombinedCsv)
        manualSavedDescription = manualSavedDescription
            + "\n- Batch__RGB_Raw_ManualROI.csv";
    if (manualSaveRoiCheck)
        manualSavedDescription = manualSavedDescription
            + "\n- one ROI-check PNG per image";
    if (manualSaveSampleCrops)
        manualSavedDescription = manualSavedDescription
            + "\n- every Sample ROI clean crop";

    print("Manual flexible-ROI batch finished.");
    print("Processed: " + manualProcessedCount);
    print("Errors: " + manualStage2ErrorCount);
    print("Output: " + manualOutputDir);

    waitForUser(
        "Manual flexible-ROI batch finished",
        "Processing is complete.\n\n"
        + "Processed images: " + manualProcessedCount + "\n"
        + "Errors: " + manualStage2ErrorCount + "\n\n"
        + "Saved:" + manualSavedDescription + "\n\n"
        + "Output folder:\n" + manualOutputDir + "\n\n"
        + "The combined CSV is the recommended input for a "
        + "separate Raw-to-Summary workbook converter."
    );
}


Dialog.create("Choose ROI workflow");
Dialog.addChoice(
    "Workflow:",
    newArray(
        "One batch ROI plan + manual positions (RECOMMENDED)",
        "Fully manual flexible ROI mode (ADDED)",
        "Original Black1-calibrated automatic mode"
    ),
    "One batch ROI plan + manual positions (RECOMMENDED)"
);
Dialog.addMessage(
    "Added version: " + MANUAL_ADDED_VERSION + "\n\n"
    + "Recommended: define reference/sample sizes and ROI order ONCE "
    + "after all input files are listed, then reuse that plan for "
    + "every image.\n\n"
    + "The fully flexible fallback can still change every ROI separately.\n"
    + "The original automatic mode below is preserved unchanged."
);
Dialog.show();
manualWorkflowMode = Dialog.getChoice();

if (manualWorkflowMode
    =="One batch ROI plan + manual positions (RECOMMENDED)") {
    MANUAL_PLANNED_SIZE_MODE = 1;
    runManualFlexibleRoiWorkflow();
    exit("Planned manual ROI workflow completed.");
}

if (manualWorkflowMode=="Fully manual flexible ROI mode (ADDED)") {
    MANUAL_PLANNED_SIZE_MODE = 0;
    runManualFlexibleRoiWorkflow();
    exit("Fully manual flexible ROI workflow completed.");
}


// ============================================================================
// USER-SELECTED INPUT LOCATION
// ============================================================================

selectedSourceRoot = getDirectory(
    "STEP 1 of 2 - Choose the INPUT folder containing images"
);
if (selectedSourceRoot=="")
    exit("No source folder was selected.");

// Keep and scan exactly the path chosen by the user. Do not resolve it to a
// different drive or replace it with a physical junction target.
sourceRoot = selectedSourceRoot;
if (!endsWith(sourceRoot, "/") && !endsWith(sourceRoot, "\\"))
    sourceRoot = sourceRoot + File.separator;

// Read one batch folder at its current level. Use two simple top-level passes:
// first count supported files, then allocate fixed-size arrays and fill them.
// This avoids recursive-function and dynamic-array differences between ImageJ
// installations while matching the intended 16-image / 8-image group workflow.
entryNames = getFileList(sourceRoot);
entryNames = Array.sort(entryNames);
scanFolderCount = 1;
scanFileCount = 0;
supportedImageCount = 0;

for (entryIndex=0; entryIndex<entryNames.length; entryIndex++) {
    entryName = entryNames[entryIndex];
    fullPath = sourceRoot + entryName;
    if (!File.isDirectory(fullPath)) {
        scanFileCount++;
        supportedEntry = isSupportedSourceImage(entryName);
        if (firstScannedFileName=="") {
            firstScannedFileName = entryName;
            firstScannedSupported = supportedEntry;
        }
        if (supportedEntry)
            supportedImageCount++;
    }
}

totalImages = supportedImageCount;
imagePaths = newArray(totalImages);
imageFileNames = newArray(totalImages);
imageRelativeFolders = newArray(totalImages);
imageOutputKeys = newArray(totalImages);

writeIndex = 0;
for (entryIndex=0; entryIndex<entryNames.length; entryIndex++) {
    entryName = entryNames[entryIndex];
    fullPath = sourceRoot + entryName;
    if (!File.isDirectory(fullPath) && isSupportedSourceImage(entryName)) {
        imagePaths[writeIndex] = fullPath;
        imageFileNames[writeIndex] = entryName;
        imageRelativeFolders[writeIndex] = "";
        imageOutputKeys[writeIndex] = makeOutputKey("", entryName);
        writeIndex++;
    }
}

scanSummary = "Macro version: " + MACRO_VERSION + "\n\n"
    + "Selected folder:\n" + sourceRoot + "\n\n"
    + "Folders scanned: " + scanFolderCount + "\n"
    + "Files found: " + scanFileCount + "\n"
    + "Supported images found: " + totalImages;
if (totalImages==0) {
    scanSummary = scanSummary
        + "\n\nScan engine: ImageJ native current-folder getFileList()"
        + "\nFirst file returned: " + firstScannedFileName
        + "\nFirst file accepted by extension filter: "
        + firstScannedSupported;
}
if (scanError!="")
    scanSummary = scanSummary + "\n\nScanner error:\n" + scanError;

if (totalImages==0)
    exit(
        "No supported JPG/JPEG/PNG/TIF/TIFF images were found.\n\n"
        + scanSummary + "\n\n"
        + "The scan uses the selected batch folder's current level only; "
        + "it does not require any particular image name."
    );

// All files are saved into one user-selected output folder. Stop before any
// Black1 clicks if two source images would produce the same output base name.
duplicateOutputNames = "";
for (firstIndex=0; firstIndex<totalImages; firstIndex++) {
    for (secondIndex=firstIndex+1; secondIndex<totalImages; secondIndex++) {
        if (toLowerCase(imageOutputKeys[firstIndex])
            ==toLowerCase(imageOutputKeys[secondIndex])) {
            duplicateOutputNames = duplicateOutputNames + "\n"
                + imagePaths[firstIndex] + "\n"
                + imagePaths[secondIndex] + "\n";
        }
    }
}
if (duplicateOutputNames!="")
    exit(
        "Two or more images have the same base file name, so saving all "
        + "results into one output folder would overwrite files.\n\n"
        + "Please select one smaller group folder, or rename the duplicate "
        + "source images before running this batch.\n"
        + duplicateOutputNames
    );

showMessage("Input scan complete", scanSummary);

// Choose output types independently. The input-folder and output-folder
// selection flow remains unchanged, and the output folder is still selected
// only once after all Black1 points have been recorded.
Dialog.create("Choose outputs to save");
Dialog.addMessage("Select one or more output types for this batch:");
Dialog.addCheckbox("Save measured raw RGB values (CSV)", true);
Dialog.addCheckbox("Save measurement locations on original image (PNG)", true);
Dialog.addCheckbox("Save four individual Well Sample1 pictures (PNG)", true);
Dialog.show();
saveRawRGB = Dialog.getCheckbox();
saveRoiCheck = Dialog.getCheckbox();
saveWellPictures = Dialog.getCheckbox();

if (!saveRawRGB && !saveRoiCheck && !saveWellPictures)
    exit("No output type was selected. Nothing was processed or saved.");

selectedOutputSummary = "";
if (saveRawRGB)
    selectedOutputSummary = selectedOutputSummary
        + "\n- Measured raw RGB values (CSV)";
if (saveRoiCheck)
    selectedOutputSummary = selectedOutputSummary
        + "\n- Measurement locations on original image (PNG)";
if (saveWellPictures)
    selectedOutputSummary = selectedOutputSummary
        + "\n- Four individual Well Sample1 pictures (PNG)";

startConfirmed = getBoolean(
    "Input folder selected:\n" + selectedSourceRoot + "\n\n"
    + "Images found in this batch folder: " + totalImages + "\n\n"
    + "First, click Black1 once for every eligible image.\n"
    + "After all Black1 points are recorded, choose ONE output folder "
    + "for the whole batch.\n\n"
    + "Selected outputs:"
    + selectedOutputSummary + "\n\n"
    + "Start now?"
);
if (!startConfirmed)
    exit("Batch cancelled before processing.");


// ============================================================================
// STAGE 1: RECORD ONE BLACK1 POINT FOR EACH ELIGIBLE SOURCE IMAGE
// ============================================================================

black1XByImage = newArray(totalImages);
black1YByImage = newArray(totalImages);
workingWByImage = newArray(totalImages);
workingHByImage = newArray(totalImages);
processImage = newArray(totalImages);
skipReason = newArray(totalImages);

print("\\Clear");
print("Raw RGB batch started.");
print("Input:  " + sourceRoot);
print("Images cached: " + totalImages);
print("Stage 1: click Black1 once per eligible image.");

readyCount = 0;
stage1SkippedCount = 0;

for (imageIndex=0; imageIndex<totalImages; imageIndex++) {
    imagePath = imagePaths[imageIndex];
    sourceFile = File.getName(imagePath);

    processImage[imageIndex] = 0;
    skipReason[imageIndex] = "";

    showProgress(imageIndex, totalImages);
    showStatus(
        "Stage 1 [" + (imageIndex+1) + "/" + totalImages
        + "] Select Black1"
    );

    openResult = openAndOrient(imagePath);
    openedOk = openResult[0];

    if (!openedOk) {
        skipReason[imageIndex] = "OPEN_FAILED";
        stage1SkippedCount++;
        print("SKIPPED open failed: " + imagePath);
    } else {
        selectionImageID = openResult[1];
        workingW = openResult[4];
        workingH = openResult[5];
        workingDepth = openResult[7];
        workingWByImage[imageIndex] = workingW;
        workingHByImage[imageIndex] = workingH;

        if (workingDepth!=24) {
            skipReason[imageIndex] = "NOT_RGB";
            stage1SkippedCount++;
            print("SKIPPED non-RGB image: " + imagePath);
        } else {
            aspectCurrent = workingW/workingH;
            aspectCalibration = CAL_W/CAL_H;

            if (abs(aspectCurrent-aspectCalibration)>0.01) {
                skipReason[imageIndex] = "INCOMPATIBLE_ASPECT_RATIO";
                stage1SkippedCount++;
                print(
                    "SKIPPED unexpected aspect ratio: " + imagePath
                    + " (working " + workingW + "x" + workingH + ")"
                );
            } else {
                anchorAccepted = 0;
                while (anchorAccepted==0) {
                    selectImage(selectionImageID);
                    selectedPoint = selectBlack1(
                        "Stage 1 [" + (imageIndex+1) + "/"
                            + totalImages + "] Select Black1",
                        "Image: " + sourceFile + "\n\n"
                        + "Click exactly once at the CENTER of Black1 "
                        + "(the upper-left black reference), then click OK."
                    );
                    pickedX = selectedPoint[0];
                    pickedY = selectedPoint[1];

                    if (allPredictedRoisFit(
                        pickedX, pickedY, workingW, workingH
                    )) {
                        black1XByImage[imageIndex] = pickedX;
                        black1YByImage[imageIndex] = pickedY;
                        processImage[imageIndex] = 1;
                        skipReason[imageIndex] = "READY";
                        readyCount++;
                        anchorAccepted = 1;
                    } else {
                        showMessage(
                            "Predicted ROI outside image",
                            "At least one predicted ROI is outside the "
                            + "image. Please select Black1 again."
                        );
                    }
                }
            }
        }

        closeWithoutSaving(selectionImageID);
    }
}

print("Stage 1 finished. Ready: " + readyCount
    + ", skipped: " + stage1SkippedCount);

if (readyCount==0)
    exit("No eligible RGB images remain after Stage 1.");

// Choose the result location once, after every Black1 point has been recorded.
selectedOutputDir = getDirectory(
    "STEP 2 of 2 - Choose ONE OUTPUT folder for this whole batch"
);
if (selectedOutputDir=="")
    exit("No output folder was selected. No results were written.");

outputDir = selectedOutputDir;
if (!endsWith(outputDir, "/") && !endsWith(outputDir, "\\"))
    outputDir = outputDir + File.separator;

// Confirm the selected destination is writable before Stage 2 starts. Use a
// unique name so an unrelated file in the chosen folder is never overwritten.
writeTestPath = outputDir + "__ImageJ_Output_Write_Test_"
    + d2s(getTime(), 0) + ".tmp";
writeTestSuffix = 0;
while (File.exists(writeTestPath)) {
    writeTestSuffix++;
    writeTestPath = outputDir + "__ImageJ_Output_Write_Test_"
        + d2s(getTime(), 0) + "_" + writeTestSuffix + ".tmp";
}
File.saveString("OK", writeTestPath);
if (!File.exists(writeTestPath) || File.length(writeTestPath)==0)
    exit("ImageJ cannot write to the selected output folder:\n" + outputDir);
File.delete(writeTestPath);
if (File.exists(writeTestPath))
    exit("ImageJ cannot remove its temporary write-test file:\n" + writeTestPath);

// Existing results are checked only now, because the output folder is chosen
// after all Black1 points have been collected. Only output types selected for
// this run take part in the existing-file check.
existingOutputCount = 0;
for (imageIndex=0; imageIndex<totalImages; imageIndex++) {
    if (processImage[imageIndex]) {
        key = imageOutputKeys[imageIndex];
        qcPath = outputDir + key + "__ROI_Check.png";
        csvPath = outputDir + key + "__RGB_Raw_3ROI.csv";
        selectedOutputExists = 0;

        if (saveRoiCheck && File.exists(qcPath))
            selectedOutputExists = 1;
        if (saveRawRGB && File.exists(csvPath))
            selectedOutputExists = 1;
        if (saveWellPictures) {
            for (wellIndex=0; wellIndex<4; wellIndex++) {
                cropPath = outputDir
                    + makeWellCropFileName(key, wellIndex);
                if (File.exists(cropPath))
                    selectedOutputExists = 1;
            }
        }

        if (selectedOutputExists)
            existingOutputCount++;
    }
}

overwriteExisting = 0;
if (existingOutputCount>0) {
    overwriteExisting = getBoolean(
        existingOutputCount
        + " source image(s) already have one or more SELECTED outputs.\n\n"
        + "YES = overwrite their existing selected output files.\n"
        + "NO = keep them and skip those source images.\n\n"
        + "Files belonging to unselected output types are never deleted."
    );
}

outputSkippedCount = 0;
if (existingOutputCount>0 && !overwriteExisting) {
    for (imageIndex=0; imageIndex<totalImages; imageIndex++) {
        if (processImage[imageIndex]) {
            key = imageOutputKeys[imageIndex];
            qcPath = outputDir + key + "__ROI_Check.png";
            csvPath = outputDir + key + "__RGB_Raw_3ROI.csv";
            selectedOutputExists = 0;

            if (saveRoiCheck && File.exists(qcPath))
                selectedOutputExists = 1;
            if (saveRawRGB && File.exists(csvPath))
                selectedOutputExists = 1;
            if (saveWellPictures) {
                for (wellIndex=0; wellIndex<4; wellIndex++) {
                    cropPath = outputDir
                        + makeWellCropFileName(key, wellIndex);
                    if (File.exists(cropPath))
                        selectedOutputExists = 1;
                }
            }

            if (selectedOutputExists) {
                processImage[imageIndex] = 0;
                skipReason[imageIndex] = "SKIPPED_EXISTING_OUTPUT";
                outputSkippedCount++;
                print("SKIPPED existing output: " + imagePaths[imageIndex]);
            }
        }
    }
}

// When overwrite is selected, remove only the selected output types and verify
// every deletion before opening the source image. A locked/read-only old file
// must never be mistaken for a successfully saved new result.
deleteFailedCount = 0;
if (existingOutputCount>0 && overwriteExisting) {
    for (imageIndex=0; imageIndex<totalImages; imageIndex++) {
        if (processImage[imageIndex]) {
            key = imageOutputKeys[imageIndex];
            qcPath = outputDir + key + "__ROI_Check.png";
            csvPath = outputDir + key + "__RGB_Raw_3ROI.csv";
            deleteFailed = 0;

            if (saveRoiCheck && File.exists(qcPath)) {
                File.delete(qcPath);
                if (File.exists(qcPath))
                    deleteFailed = 1;
            }
            if (saveRawRGB && File.exists(csvPath)) {
                File.delete(csvPath);
                if (File.exists(csvPath))
                    deleteFailed = 1;
            }
            if (saveWellPictures) {
                for (wellIndex=0; wellIndex<4; wellIndex++) {
                    cropPath = outputDir
                        + makeWellCropFileName(key, wellIndex);
                    if (File.exists(cropPath)) {
                        File.delete(cropPath);
                        if (File.exists(cropPath))
                            deleteFailed = 1;
                    }
                }
            }

            if (deleteFailed) {
                processImage[imageIndex] = 0;
                skipReason[imageIndex] = "DELETE_FAILED";
                deleteFailedCount++;
                print("SKIPPED unable to replace locked/read-only output: "
                    + imagePaths[imageIndex]);
            }
        }
    }
}

print("Output: " + outputDir);
print("Stage 2: automatic ROI creation, measurement and saving.");


// ============================================================================
// STAGE 2: RECONSTRUCT ROIS AND SAVE THE USER-SELECTED OUTPUT TYPES
// ============================================================================

processedCount = 0;
stage2SkippedCount = 0;

for (imageIndex=0; imageIndex<totalImages; imageIndex++) {
    imagePath = imagePaths[imageIndex];
    sourceFile = File.getName(imagePath);
    sourceStem = File.getNameWithoutExtension(sourceFile);
    sourceFolder = folderLabel(imageRelativeFolders[imageIndex]);
    key = imageOutputKeys[imageIndex];
    qcPath = outputDir + key + "__ROI_Check.png";
    csvPath = outputDir + key + "__RGB_Raw_3ROI.csv";

    showProgress(imageIndex, totalImages);
    showStatus(
        "Stage 2 [" + (imageIndex+1) + "/" + totalImages
        + "] Preparing selected outputs"
    );

    if (processImage[imageIndex]) {
        openResult = openAndOrient(imagePath);
        openedOk = openResult[0];

        if (!openedOk) {
            skipReason[imageIndex] = "OPEN_FAILED_STAGE2";
            stage2SkippedCount++;
            print("SKIPPED Stage 2 open failed: " + imagePath);
        } else {
            originalImageID = openResult[1];
            imageW = openResult[4];
            imageH = openResult[5];
            imageDepth = openResult[7];

            if (imageDepth!=24
                || imageW!=workingWByImage[imageIndex]
                || imageH!=workingHByImage[imageIndex]) {
                skipReason[imageIndex] = "IMAGE_CHANGED_AFTER_STAGE1";
                stage2SkippedCount++;
                print("SKIPPED image changed after Stage 1: " + imagePath);
                closeWithoutSaving(originalImageID);
            } else {
                scaleX = imageW/CAL_W;
                scaleY = imageH/CAL_H;
                black1X = black1XByImage[imageIndex];
                black1Y = black1YByImage[imageIndex];

                black2X = black1X
                    + (CAL_BLACK2_X-CAL_BLACK1_X)*scaleX;
                black2Y = black1Y
                    + (CAL_BLACK2_Y-CAL_BLACK1_Y)*scaleY;
                white1X = black1X
                    + (CAL_WHITE1_X-CAL_BLACK1_X)*scaleX;
                white1Y = black1Y
                    + (CAL_WHITE1_Y-CAL_BLACK1_Y)*scaleY;
                white2X = black1X
                    + (CAL_WHITE2_X-CAL_BLACK1_X)*scaleX;
                white2Y = black1Y
                    + (CAL_WHITE2_Y-CAL_BLACK1_Y)*scaleY;

                wellX = newArray(4);
                wellY = newArray(4);
                for (wellIndex=0; wellIndex<4; wellIndex++) {
                    wellX[wellIndex] = black1X
                        + (CAL_WELL_X[wellIndex]-CAL_BLACK1_X)*scaleX;
                    wellY[wellIndex] = black1Y
                        + (CAL_WELL_Y[wellIndex]-CAL_BLACK1_Y)*scaleY;
                }

                // Dynamically draw all 20 positions during automatic Stage 2:
                // 4 references, 4 well centers and 12 measurement ROIs.
                // All drawing is done in the main loop so each new circle is
                // forced onto the visible canvas before the next one is added.
                selectImage(originalImageID);
                roiManager("Reset");
                Overlay.clear;
                setColor("yellow");

                dynamicRefX = newArray(
                    black1X, black2X, white1X, white2X
                );
                dynamicRefY = newArray(
                    black1Y, black2Y, white1Y, white2Y
                );
                for (dynamicRefIndex=0;
                    dynamicRefIndex<4;
                    dynamicRefIndex++) {
                    makeOval(
                        dynamicRefX[dynamicRefIndex]-REFERENCE_ROI_W/2,
                        dynamicRefY[dynamicRefIndex]-REFERENCE_ROI_H/2,
                        REFERENCE_ROI_W, REFERENCE_ROI_H
                    );
                    roiManager("Add");
                    dynamicCount = roiManager("count");
                    roiManager("Select", dynamicCount-1);
                    roiManager(
                        "Rename", REFERENCE_NAME[dynamicRefIndex]
                    );
                    Overlay.drawEllipse(
                        dynamicRefX[dynamicRefIndex]-REFERENCE_ROI_W/2,
                        dynamicRefY[dynamicRefIndex]-REFERENCE_ROI_H/2,
                        REFERENCE_ROI_W, REFERENCE_ROI_H
                    );
                    Overlay.add;
                    Overlay.drawString(
                        "" + (dynamicRefIndex+1),
                        dynamicRefX[dynamicRefIndex],
                        dynamicRefY[dynamicRefIndex]
                    );
                    Overlay.add;
                    Overlay.show;
                    showStatus(
                        "Stage 2 [" + (imageIndex+1) + "/" + totalImages
                        + "] Adding " + REFERENCE_NAME[dynamicRefIndex]
                    );
                    wait(ROI_STEP_PREVIEW_MS);
                }

                for (dynamicWellIndex=0;
                    dynamicWellIndex<4;
                    dynamicWellIndex++) {
                    makeOval(
                        wellX[dynamicWellIndex]-WELL_CENTER_MARKER/2,
                        wellY[dynamicWellIndex]-WELL_CENTER_MARKER/2,
                        WELL_CENTER_MARKER, WELL_CENTER_MARKER
                    );
                    roiManager("Add");
                    dynamicCount = roiManager("count");
                    roiManager("Select", dynamicCount-1);
                    roiManager(
                        "Rename",
                        "QC_Well" + (dynamicWellIndex+1) + "_Center"
                    );
                    Overlay.drawEllipse(
                        wellX[dynamicWellIndex]-WELL_CENTER_MARKER/2,
                        wellY[dynamicWellIndex]-WELL_CENTER_MARKER/2,
                        WELL_CENTER_MARKER, WELL_CENTER_MARKER
                    );
                    Overlay.add;
                    Overlay.drawString(
                        "" + (dynamicWellIndex+5),
                        wellX[dynamicWellIndex],
                        wellY[dynamicWellIndex]
                    );
                    Overlay.add;
                    Overlay.show;
                    showStatus(
                        "Stage 2 [" + (imageIndex+1) + "/" + totalImages
                        + "] Adding well center " + (dynamicWellIndex+1)
                    );
                    wait(ROI_STEP_PREVIEW_MS);
                }

                sampleAngles = newArray(-90, 30, 150);
                PI_VALUE = 3.141592653589793;
                for (dynamicWellIndex=0;
                    dynamicWellIndex<4;
                    dynamicWellIndex++) {
                    for (dynamicSampleIndex=0;
                        dynamicSampleIndex<3;
                        dynamicSampleIndex++) {
                        dynamicRadians = sampleAngles[dynamicSampleIndex]
                            * PI_VALUE/180;
                        dynamicSampleX = wellX[dynamicWellIndex]
                            + SAMPLE_SPREAD*cos(dynamicRadians);
                        dynamicSampleY = wellY[dynamicWellIndex]
                            + SAMPLE_SPREAD*sin(dynamicRadians);
                        makeOval(
                            dynamicSampleX-ROI_W/2,
                            dynamicSampleY-ROI_H/2,
                            ROI_W, ROI_H
                        );
                        roiManager("Add");
                        dynamicCount = roiManager("count");
                        roiManager("Select", dynamicCount-1);
                        roiManager(
                            "Rename",
                            "W" + (dynamicWellIndex+1)
                                + "_ROI" + (dynamicSampleIndex+1)
                        );
                        Overlay.drawEllipse(
                            dynamicSampleX-ROI_W/2,
                            dynamicSampleY-ROI_H/2,
                            ROI_W, ROI_H
                        );
                        Overlay.add;
                        Overlay.drawString(
                            "" + (
                                9 + dynamicWellIndex*3
                                    + dynamicSampleIndex
                            ),
                            dynamicSampleX,
                            dynamicSampleY
                        );
                        Overlay.add;
                        Overlay.show;
                        showStatus(
                            "Stage 2 [" + (imageIndex+1) + "/"
                            + totalImages + "] Adding well "
                            + (dynamicWellIndex+1) + " sample "
                            + (dynamicSampleIndex+1)
                        );
                        wait(ROI_STEP_PREVIEW_MS);
                    }
                }

                Overlay.show;
                showStatus(
                    "Stage 2 [" + (imageIndex+1) + "/" + totalImages
                    + "] Complete 20-ROI layout: " + sourceFile
                );
                wait(COMPLETE_LAYOUT_PREVIEW_MS);

                // ROI Manager indices 8, 11, 14 and 17 are Sample1 for the
                // four wells. Save only each Sample1 bounding square as a
                // clean 60 x 60 crop; Sample2 and Sample3 remain RGB-only.
                sampleStartIndex = 8;
                if (saveWellPictures) {
                    for (wellIndex=0; wellIndex<4; wellIndex++) {
                        selectImage(originalImageID);
                        roiIndex = sampleStartIndex + wellIndex*3;
                        roiManager("Select", roiIndex);
                        getSelectionBounds(cropX, cropY, cropW, cropH);
                        makeRectangle(cropX, cropY, cropW, cropH);
                        run(
                            "Duplicate...",
                            "title=__WellCrop_" + (wellIndex+1)
                        );
                        cropImageID = getImageID();
                        selectImage(cropImageID);
                        Overlay.clear;
                        run("Select None");
                        cropPath = outputDir
                            + makeWellCropFileName(key, wellIndex);
                        saveAs("PNG", cropPath);
                        closeWithoutSaving(cropImageID);
                    }
                }

                // Always clear the active selection before duplicating the
                // full source image or flattening the ROI-check overlay.
                selectImage(originalImageID);
                run("Select None");

                // Save exactly one image containing all sampling locations.
                if (saveRoiCheck) {
                    run("Flatten");
                    qcImageID = getImageID();
                    saveAs("PNG", qcPath);
                    closeWithoutSaving(qcImageID);
                }

                // Measure raw R/G/B without altering the source photograph.
                // The original 4 references plus 4 wells x 3 ROIs are kept.
                if (saveRawRGB) {
                    selectImage(originalImageID);
                    run("Select None");
                    run(
                        "Duplicate...",
                        "title=__RGB_measurement_" + (imageIndex+1)
                    );
                    measurementImageID = getImageID();
                    run("RGB Stack");

                    csvText = "Image_Index,Source_Folder,Source_File,Region,"
                        + "Well_Position,ROI_Number,R,G,B\n";

                    // Raw measurements for Black1, Black2, White1 and White2.
                    for (referenceIndex=0; referenceIndex<4; referenceIndex++) {
                        roiManager("Select", referenceIndex);
                        setSlice(1);
                        getStatistics(
                            area, meanR, minValue, maxValue, channelSD
                        );
                        setSlice(2);
                        getStatistics(
                            area, meanG, minValue, maxValue, channelSD
                        );
                        setSlice(3);
                        getStatistics(
                            area, meanB, minValue, maxValue, channelSD
                        );

                        csvText = csvText
                            + (imageIndex+1) + ","
                            + csvQuote(sourceFolder) + ","
                            + csvQuote(sourceFile) + ","
                            + REFERENCE_NAME[referenceIndex] + ",,,"
                            + d2s(meanR, 3) + ","
                            + d2s(meanG, 3) + ","
                            + d2s(meanB, 3) + "\n";
                    }

                    // Raw measurements for three 60 x 60 ROIs in each well.
                    for (wellIndex=0; wellIndex<4; wellIndex++) {
                        for (sampleIndex=0; sampleIndex<3; sampleIndex++) {
                            roiIndex = sampleStartIndex
                                + wellIndex*3 + sampleIndex;
                            roiManager("Select", roiIndex);
                            setSlice(1);
                            getStatistics(
                                area, meanR, minValue, maxValue, channelSD
                            );
                            setSlice(2);
                            getStatistics(
                                area, meanG, minValue, maxValue, channelSD
                            );
                            setSlice(3);
                            getStatistics(
                                area, meanB, minValue, maxValue, channelSD
                            );

                            csvText = csvText
                                + (imageIndex+1) + ","
                                + csvQuote(sourceFolder) + ","
                                + csvQuote(sourceFile) + ","
                                + "Sample" + (sampleIndex+1) + ","
                                + WELL_POSITION[wellIndex] + ","
                                + (sampleIndex+1) + ","
                                + d2s(meanR, 3) + ","
                                + d2s(meanG, 3) + ","
                                + d2s(meanB, 3) + "\n";
                        }
                    }

                    File.saveString(csvText, csvPath);
                    closeWithoutSaving(measurementImageID);
                }

                closeWithoutSaving(originalImageID);
                roiManager("Reset");

                selectedOutputsSaved = 1;
                if (saveRoiCheck
                    && (!File.exists(qcPath) || File.length(qcPath)==0))
                    selectedOutputsSaved = 0;
                if (saveRawRGB
                    && (!File.exists(csvPath) || File.length(csvPath)==0))
                    selectedOutputsSaved = 0;
                if (saveWellPictures) {
                    for (wellIndex=0; wellIndex<4; wellIndex++) {
                        cropPath = outputDir
                            + makeWellCropFileName(key, wellIndex);
                        if (!File.exists(cropPath)
                            || File.length(cropPath)==0)
                            selectedOutputsSaved = 0;
                    }
                }

                if (selectedOutputsSaved) {
                    processedCount++;
                    skipReason[imageIndex] = "SAVED";
                    print(
                        "SAVED [" + (imageIndex+1) + "/"
                        + totalImages + "]: " + sourceFile
                    );
                    if (saveRoiCheck)
                        print("  ROI check: " + qcPath);
                    if (saveRawRGB)
                        print("  Raw RGB:   " + csvPath);
                    if (saveWellPictures) {
                        for (wellIndex=0; wellIndex<4; wellIndex++) {
                            cropPath = outputDir
                                + makeWellCropFileName(key, wellIndex);
                            print("  Well Sample1: " + cropPath);
                        }
                    }
                } else {
                    stage2SkippedCount++;
                    skipReason[imageIndex] = "SAVE_FAILED";
                    print("SAVE FAILED: " + imagePath);
                }
            }
        }
    }
}
    
showProgress(1, 1);
showStatus("Selected-output batch finished.");

print("Batch finished.");
print("Processed: " + processedCount);
print("Stage 1 skipped: " + stage1SkippedCount);
print("Existing outputs skipped: " + outputSkippedCount);
print("Output replacement errors: " + deleteFailedCount);
print("Stage 2 errors:  " + stage2SkippedCount);
print("Output selected by user: " + outputDir);

waitForUser(
    "Batch finished",
    "Processing is complete.\n\n"
    + "Processed images: " + processedCount + "\n"
    + "Skipped/errors: "
        + (stage1SkippedCount+outputSkippedCount
            + deleteFailedCount+stage2SkippedCount)
        + "\n\n"
    + "Saved for each processed source image:"
    + selectedOutputSummary + "\n\n"
    + "Well pictures, when selected, are 4 clean 60 x 60 Sample1 PNGs.\n\n"
    + "Output folder:\n" + outputDir
);

using System;
using System.Drawing;
using System.Windows.Forms;
using Tesseract;
using Emgu.CV;
using Emgu.CV.CvEnum;
using Emgu.CV.Structure;
using System.Threading.Tasks;
using System.Linq;
using System.IO;
using System.Drawing.Imaging;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;




namespace OCRApp
{
    public partial class Form1 : Form
    {
        private readonly Color CardColorRed = ColorTranslator.FromHtml("#E90000");
        private readonly Color CardColorBlue = ColorTranslator.FromHtml("#0952B7");
        private readonly Color CardColorGrey = ColorTranslator.FromHtml("#565656");
        private readonly Color CardColorGreen = ColorTranslator.FromHtml("#009024");

        private readonly Rectangle rankRegion = new Rectangle(1954, 1390, 54, 96);
        private readonly Rectangle rankRegion2 = new Rectangle(2052, 1388, 57, 91);
        private readonly Rectangle rankRegion3 = new Rectangle(2150, 1387, 52, 95);
        private readonly Rectangle suitRegion = new Rectangle(1966, 1382, 23, 14);
        private readonly Rectangle suitRegion2 = new Rectangle(2065, 1377, 27, 17);
        private readonly Rectangle suitRegion3 = new Rectangle(2162, 1378, 31, 15);

        private readonly Rectangle seat1Region = new Rectangle(2390, 1802, 117, 35);
        private readonly Rectangle seat2Region = new Rectangle(2766, 1501, 131, 35);
        private readonly Rectangle seat3Region = new Rectangle(2318, 1207, 131, 41);
        private readonly Rectangle seat4Region = new Rectangle(1943, 1213, 131, 35);
        private readonly Rectangle seat5Region = new Rectangle(1600, 1502, 131, 35);
        private readonly Rectangle seat6Region = new Rectangle(1946, 1802, 131, 35);
              
        private readonly Rectangle potRegion = new Rectangle(2174, 1443, 121, 43);

        private List<string> cardOutputs = new List<string>();

        private readonly List<string> ExpectedRanks = new List<string> { "A", "2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K" };

        private List<string> activeSeats = new List<string>();

        private readonly Dictionary<string, Rectangle> buttonLocations = new Dictionary<string, Rectangle>
    {
        {"seat1", new Rectangle(2535, 1621, 65, 65)},
        {"seat2", new Rectangle(2605, 1404, 70, 55)},
        {"seat3", new Rectangle(2527, 1264, 68, 56)},
        {"seat4", new Rectangle(2089, 1255, 62, 55)},
        {"seat5", new Rectangle(1799, 1393, 80, 80)},
        {"seat6", new Rectangle(2085, 1624, 70, 58)}
    };

        

        public Form1()
        {
            InitializeComponent();
           
        }

        private async void btnExtractText_Click(object sender, EventArgs e)
        {
            txtConsole.Text = string.Empty;  // Clear previous prints

            // Detect the button concurrently with other operations
            var buttonSeatTask = Task.Run(() => DetectAndLogButton());

            var otherTasks = Task.WhenAll(
                Task.Run(() => ProcessCard(rankRegion, suitRegion)),
                Task.Run(() => ProcessCard(rankRegion2, suitRegion2)),
                Task.Run(() => ProcessCard(rankRegion3, suitRegion3)),
                Task.Run(() => ProcessPotValue(potRegion)),
                Task.Run(() => ProcessSeatStack(seat1Region)),
                Task.Run(() => ProcessSeatStack(seat2Region)),
                Task.Run(() => ProcessSeatStack(seat3Region)),
                Task.Run(() => ProcessSeatStack(seat4Region)),
                Task.Run(() => ProcessSeatStack(seat5Region)),
                Task.Run(() => ProcessSeatStack(seat6Region))
            );

            // Await the button seat detection task
            string buttonSeat = await buttonSeatTask;

            // If the button is detected, identify the blinds
            if (buttonSeat != null)
            {
                IdentifyBlinds(buttonSeat);
            }

            // Await the rest of the tasks
            await otherTasks;
        }


        private Image<Gray, byte> BinarizeImage(Image<Bgr, byte> inputImage)
        {
            // Convert the input image to grayscale
            Image<Gray, byte> grayImage = inputImage.Convert<Gray, byte>();

            // Apply adaptive thresholding to binarize the image
            CvInvoke.Threshold(grayImage, grayImage, 0, 255, ThresholdType.Binary | ThresholdType.Otsu);

            return grayImage;
        }
        private string DetectAndLogButton()
        {
            Color buttonColor = Color.FromArgb(251, 213, 127);
            string detectedRegion = DetectButtonLocation(buttonColor);

            if (detectedRegion != null)
            {
                txtConsole.Invoke((Action)(() => txtConsole.AppendText($"Button found in {detectedRegion}!" + Environment.NewLine)));
                return detectedRegion; // Return the seat where the button is located.
            }
            else
            {
                txtConsole.Invoke((Action)(() => txtConsole.AppendText("Button not found in any region." + Environment.NewLine)));
                return null;
            }
        }


        private string DetectButtonLocation(Color buttonColor, int colorTolerance = 100)
        {
            foreach (var entry in buttonLocations)
            {
                string regionName = entry.Key;
                Rectangle location = entry.Value;

                Bitmap capturedBitmap = new Bitmap(location.Width, location.Height, PixelFormat.Format32bppArgb);
                Graphics g = Graphics.FromImage(capturedBitmap);
                g.CopyFromScreen(location.Location, Point.Empty, location.Size);
                capturedBitmap.Save($"debug_{regionName}.png", System.Drawing.Imaging.ImageFormat.Png);

                for (int y = 0; y < capturedBitmap.Height; y++)
                {
                    for (int x = 0; x < capturedBitmap.Width; x++)
                    {
                        Color pixel = capturedBitmap.GetPixel(x, y);

                        if (Math.Abs(pixel.R - buttonColor.R) <= colorTolerance &&
                            Math.Abs(pixel.G - buttonColor.G) <= colorTolerance &&
                            Math.Abs(pixel.B - buttonColor.B) <= colorTolerance)
                        {
                            return regionName;
                        }
                    }
                }
            }
            return null;
        }

        private void IdentifyBlinds(string buttonSeat)
        {
            int buttonSeatNumber = int.Parse(buttonSeat.Replace("seat", ""));

            int smallBlindSeatNumber = GetNextActiveSeat(buttonSeatNumber);
            int bigBlindSeatNumber = GetNextActiveSeat(smallBlindSeatNumber);

            string smallBlindSeat = $"seat{smallBlindSeatNumber}";
            string bigBlindSeat = $"seat{bigBlindSeatNumber}";

            txtConsole.Invoke((Action)(() =>
            {
                txtConsole.AppendText($"Small Blind is at {smallBlindSeat}." + Environment.NewLine);
                txtConsole.AppendText($"Big Blind is at {bigBlindSeat}." + Environment.NewLine);
            }));
        }

        private int GetNextActiveSeat(int currentSeatNumber)
        {
            int nextSeatNumber = currentSeatNumber == 6 ? 1 : currentSeatNumber + 1;

            while (!activeSeats.Contains($"seat{nextSeatNumber}"))
            {
                nextSeatNumber = nextSeatNumber == 6 ? 1 : nextSeatNumber + 1;
            }

            return nextSeatNumber;
        }

        private void ProcessSeatStack(Rectangle region)
        {
            Bitmap seatBmp = CaptureScreen(region);

            if (seatBmp == null || seatBmp.Width == 0 || seatBmp.Height == 0)
            {
                txtConsole.Invoke((Action)(() =>
                {
                    txtConsole.AppendText($"Error: Captured image for seat region {region} is invalid." + Environment.NewLine);
                }));
                return;
            }

            double scaleFactor = 2.0;
            Image<Bgr, byte> resizedSeatBmpImage = seatBmp.ToImage<Bgr, byte>().Resize(scaleFactor, Inter.Linear);
            Image<Gray, byte> binarizedSeatImage = BinarizeImage(resizedSeatBmpImage);
            Bitmap binarizedSeatBmp = binarizedSeatImage.ToBitmap();

            string seatName = region == seat1Region ? "seat1" :
                              region == seat2Region ? "seat2" :
                              region == seat3Region ? "seat3" :
                              region == seat4Region ? "seat4" :
                              region == seat5Region ? "seat5" :
                              region == seat6Region ? "seat6" :
                              "unknown";

            string savePath = $@"C:\Users\dave\Desktop\imagedebug\{seatName}_binarized.png";
            binarizedSeatBmp.Save(savePath, System.Drawing.Imaging.ImageFormat.Png);

            string extractedStackSize = PerformOCR(binarizedSeatImage.ToBitmap());


            if (string.IsNullOrEmpty(extractedStackSize) || (extractedStackSize.Length <= 2 && !decimal.TryParse(extractedStackSize, out _)))
            {
                lock (activeSeats)
                {
                    activeSeats.Remove(seatName);
                }

                txtConsole.Invoke((Action)(() =>
                {
                    txtConsole.AppendText($"{seatName} is empty or player is sitting out." + Environment.NewLine);
                }));
                return;
            }

            extractedStackSize = new string(extractedStackSize.Where(c => char.IsDigit(c) || c == '.').ToArray());
            if (decimal.TryParse(extractedStackSize, out _))
            {
                lock (activeSeats)
                {
                    if (!activeSeats.Contains(seatName))
                        activeSeats.Add(seatName);
                }
            }
            else
            {
                txtConsole.Invoke((Action)(() =>
                {
                    txtConsole.AppendText($"Error: Unable to detect a valid stack size for {seatName} from OCR result." + Environment.NewLine);
                }));
                return;
            }

            txtConsole.Invoke((Action)(() =>
            {
                txtConsole.AppendText($"{seatName} Stack Size: {extractedStackSize}" + Environment.NewLine);
            }));
        }


        private void ProcessPotValue(Rectangle region)
        {
            // Capture screenshot of the pot region
            Bitmap potBmp = CaptureScreen(region);

            // Resize the captured image for better OCR accuracy
            double scaleFactor = 2.0; // Adjust this value as necessary
            Image<Bgr, byte> resizedPotBmpImage = potBmp.ToImage<Bgr, byte>().Resize(scaleFactor, Inter.Linear);

            // Binarize the resized screenshot
            Image<Gray, byte> binarizedPotImage = BinarizeImage(resizedPotBmpImage);
            Bitmap binarizedPotBmp = binarizedPotImage.ToBitmap();

            // Debug: Save the binarized pot region for inspection
            binarizedPotBmp.Save("debug_binarized_potRegion.png");

            // Perform OCR on the binarized image
            string extractedPotValue = PerformOCR(binarizedPotBmp);

            // Refine the OCR result to ensure only numbers and a decimal point remain
            extractedPotValue = new string(extractedPotValue.Where(c => char.IsDigit(c) || c == '.').ToArray());

            // If the result is not a valid number, you can log an error or handle as needed
            if (!decimal.TryParse(extractedPotValue, out _))
            {
                txtConsole.Invoke((Action)(() =>
                {
                    txtConsole.AppendText($"Error: Unable to detect a valid pot value from OCR result." + Environment.NewLine);
                }));
                return;
            }

            txtConsole.Invoke((Action)(() =>
            {
                txtConsole.AppendText($"Detected Pot Value: {extractedPotValue}" + Environment.NewLine);
            }));
        }
        
        private void ProcessCard(Rectangle rankRegion, Rectangle suitRegion)
        {
            // Capture screenshot of rank region
            Bitmap rankBmp = CaptureScreen(rankRegion);

            double scaleFactor = 2.0;
            Image<Bgr, byte> resizedRankBmpImage = rankBmp.ToImage<Bgr, byte>().Resize(scaleFactor, Inter.Linear);

            // Convert to grayscale
            Image<Gray, byte> grayImage = resizedRankBmpImage.Convert<Gray, byte>();

            // Use dilation to emphasize the text
            var kernel = CvInvoke.GetStructuringElement(ElementShape.Rectangle, new Size(3, 3), new Point(-1, -1));
            Image<Gray, byte> dilatedImage = grayImage.MorphologyEx(MorphOp.Dilate, kernel, new Point(-1, -1), 1, BorderType.Reflect, new MCvScalar());

            // Binarization using Otsu's thresholding
            Image<Gray, byte> binarizedImage = dilatedImage.ThresholdBinary(new Gray(127), new Gray(255));

            // Get rank using OCR on the binarized image
            Bitmap cleanedBitmap = binarizedImage.ToBitmap();
            string extractedRank = PerformOCR(cleanedBitmap, true);


            // Debug: Save the binarized rank region for inspection
            if (rankRegion == this.rankRegion)
            {
                cleanedBitmap.Save("debug_binarized_rankRegion1.png");
            }
            else if (rankRegion == this.rankRegion2)
            {
                cleanedBitmap.Save("debug_binarized_rankRegion2.png");
            }
            else if (rankRegion == this.rankRegion3)
            {
                cleanedBitmap.Save("debug_binarized_rankRegion3.png");
            }

            // Correct OCR misinterpretations
            if (extractedRank == "1")
            {
                extractedRank = "Q";
            }

            // Validate extracted rank against whitelist
            if (!ExpectedRanks.Contains(extractedRank))
            {
                // Handle unexpected rank value
                txtConsole.Invoke((Action)(() =>
                {
                    txtConsole.AppendText($"Error: Unexpected rank value detected: {extractedRank}." + Environment.NewLine);
                }));
                return;  // Or any other action you want to perform
            }

            // Capture screenshot of suit region
            Bitmap suitBmp = CaptureScreen(suitRegion);

            // Check dominant color for the suit
            string detectedSuit;
            Color dominantColor = GetDominantColor(suitBmp);
            if (IsColorCloseTo(dominantColor, CardColorRed))
            {
                detectedSuit = "Hearts";
            }
            else if (IsColorCloseTo(dominantColor, CardColorBlue))
            {
                detectedSuit = "Diamonds";
            }
            else if (IsColorCloseTo(dominantColor, CardColorGreen))
            {
                detectedSuit = "Clubs";
            }
            else if (IsColorCloseTo(dominantColor, CardColorGrey))
            {
                detectedSuit = "Spades";
            }
            else
            {
                detectedSuit = "Uncertain";
            }

            // Consolidate the rank and suit into a single string and add it to cardOutputs
            cardOutputs.Add($"{extractedRank} {detectedSuit}");
        }
        
        private Bitmap CaptureScreen(Rectangle region)
        {
            Bitmap bmp = new Bitmap(region.Width, region.Height);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.CopyFromScreen(region.Location, Point.Empty, region.Size);
            }
            return bmp;
        }

        private Color GetDominantColor(Bitmap image)
        {
            long sumR = 0, sumG = 0, sumB = 0;
            int pixelCount = 0;

            for (int y = 0; y < image.Height; y++)
            {
                for (int x = 0; x < image.Width; x++)
                {
                    Color pixelColor = image.GetPixel(x, y);
                    sumR += pixelColor.R;
                    sumG += pixelColor.G;
                    sumB += pixelColor.B;
                    pixelCount++;
                }
            }

            int avgR = (int)(sumR / pixelCount);
            int avgG = (int)(sumG / pixelCount);
            int avgB = (int)(sumB / pixelCount);

            return Color.FromArgb(avgR, avgG, avgB);
        }

        private bool IsColorCloseTo(Color a, Color b, int threshold = 40)
        {
            return Math.Abs(a.R - b.R) < threshold &&
                   Math.Abs(a.G - b.G) < threshold &&
                   Math.Abs(a.B - b.B) < threshold;
        }

        private string PerformOCR(Bitmap image, bool isCardRank = false)
        {
            string resultText;
            using (var engine = new TesseractEngine(@"C:\Users\dave\Desktop\OCRApp\OCRApp\OCRApp\bin\Debug\tessdata", "eng", EngineMode.Default))
            {
                engine.SetVariable("tessedit_char_whitelist", "0123456789TJQKA.");

                if (isCardRank)
                {
                    engine.DefaultPageSegMode = PageSegMode.SingleChar;  // Set PSM to single character
                }
                else
                {
                    engine.DefaultPageSegMode = PageSegMode.SparseText;  // Or any other PSM that fits your other cases
                }

                using (var pix = PixConverter.ToPix(image))
                {
                    using (var page = engine.Process(pix))
                    {
                        resultText = page.GetText();
                    }
                }
            }
            resultText = resultText.Trim();

            // Convert "10" to "T" only if it's for card rank
            if (isCardRank && resultText == "10")
            {
                resultText = "T";
            }

            return resultText;
        }

    }
}


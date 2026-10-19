package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type TranslationRequest struct {
	Text       string `json:"text"`
	SourceLang string `json:"sourceLang"`
	TargetLang string `json:"targetLang"`
}

type GoogleTranslationResponse []interface{}

func translateHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "https://learn.srilakshmiretail.in")
	w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)
		return
	}

	if r.Method != http.MethodPost {
		http.Error(w, "Only POST requests are allowed", http.StatusMethodNotAllowed)
		return
	}

	var request TranslationRequest

	err := json.NewDecoder(r.Body).Decode(&request)
	if err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	text := strings.TrimSpace(request.Text)

	if text == "" {
		http.Error(w, "Text cannot be empty", http.StatusBadRequest)
		return
	}

	source, sourceOK := languageCode(request.SourceLang)
	target, targetOK := languageCode(request.TargetLang)

	if !sourceOK || !targetOK {
		http.Error(w, "Unsupported language", http.StatusBadRequest)
		return
	}

	if source == target {
		json.NewEncoder(w).Encode(map[string]string{
			"translation": text,
		})
		return
	}
	if translated, ok := knownTranslation(text, source, target); ok {
		json.NewEncoder(w).Encode(map[string]string{
			"translation": translated,
		})
		return
	}

	// Split long text into safe chunks.
	chunks := splitText(text, 400)

	var translations []string

	for _, chunk := range chunks {
		translated, err := translateChunk(chunk, source, target)

		if err != nil {
			fmt.Println("Translation error:", err)
			http.Error(w, "Translation failed", http.StatusBadGateway)
			return
		}

		translations = append(translations, translated)
	}

	result := map[string]string{
		"translation": strings.Join(translations, " "),
	}

	json.NewEncoder(w).Encode(result)
}

func translateChunk(text string, source string, target string) (string, error) {
	apiURL := "https://api.mymemory.translated.net/get"

	params := url.Values{}
	params.Set("q", text)
	params.Set("langpair", source+"|"+target)

	client := &http.Client{
		Timeout: 10 * time.Second,
	}
	response, err := client.Get(apiURL + "?" + params.Encode())
	if err != nil {
		return "", err
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		return "", fmt.Errorf(
			"MyMemory returned status %d: %s",
			response.StatusCode,
			string(body),
		)
	}

	var data struct {
		ResponseData struct {
			TranslatedText string `json:"translatedText"`
		} `json:"responseData"`
	}

	err = json.NewDecoder(response.Body).Decode(&data)
	if err != nil {
		return "", err
	}
	translation := strings.TrimSpace(data.ResponseData.TranslatedText)
	if translation == "" {
		return "", fmt.Errorf("empty translation response")
	}

	if strings.Contains(strings.ToUpper(translation), "QUERY LENGTH LIMIT EXCEEDED") ||
		strings.Contains(strings.ToUpper(translation), "QUERY LENGTH LIMIT EXCEDEED") {
		return "", fmt.Errorf("MyMemory returned a query length limit error")
	}

	return translation, nil
}

func splitText(text string, maxLength int) []string {

	words := strings.Fields(text)

	var chunks []string
	var current string

	for _, word := range words {

		// If one word itself is longer than the limit.
		if len(word) > maxLength {
			if current != "" {
				chunks = append(chunks, current)
				current = ""
			}

			chunks = append(chunks, word)
			continue
		}

		if len(current)+len(word)+1 > maxLength {

			if current != "" {
				chunks = append(chunks, current)
			}

			current = word

		} else {

			if current == "" {
				current = word
			} else {
				current += " " + word
			}
		}
	}

	if current != "" {
		chunks = append(chunks, current)
	}

	return chunks
}

func languageCode(language string) (string, bool) {
	codes := map[string]string{
		"English":    "en",
		"Tamil":      "ta",
		"Hindi":      "hi",
		"Telugu":     "te",
		"Malayalam":  "ml",
		"Kannada":    "kn",
		"Bengali":    "bn",
		"Marathi":    "mr",
		"Gujarati":   "gu",
		"Punjabi":    "pa",
		"Urdu":       "ur",
		"Spanish":    "es",
		"French":     "fr",
		"German":     "de",
		"Italian":    "it",
		"Portuguese": "pt",
		"Japanese":   "ja",
		"Korean":     "ko",
		"Chinese":    "zh-CN",
		"Arabic":     "ar",
		"Russian":    "ru",
		"Dutch":      "nl",
		"Turkish":    "tr",
		"Indonesian": "id",
		"Polish":     "pl",
	}

	code, ok := codes[strings.TrimSpace(language)]
	return code, ok
}

func knownTranslation(text, source, target string) (string, bool) {
	if source != "en" || target != "ta" {
		return "", false
	}

	phrases := map[string]string{
		"hello":                "வணக்கம்",
		"hi":                   "வணக்கம்",
		"thank you":            "நன்றி",
		"good morning":         "காலை வணக்கம்",
		"how are you?":         "நீங்கள் எப்படி இருக்கிறீர்கள்?",
		"where are you going?": "நீங்கள் எங்கே போகிறீர்கள்?",
		"hello, how are you?":  "வணக்கம், நீங்கள் எப்படி இருக்கிறீர்கள்?",
		"hello how are you":    "வணக்கம், நீங்கள் எப்படி இருக்கிறீர்கள்?",
	}

	translation, ok := phrases[strings.ToLower(strings.TrimSpace(text))]
	return translation, ok
}

func main() {

	http.HandleFunc("/translate", translateHandler)

	fmt.Println("Translation backend running on https://localhost:8080")

	err := http.ListenAndServe(":8080", nil)

	if err != nil {
		panic(err)
	}
}

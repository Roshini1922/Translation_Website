package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

type TranslationRequest struct {
	Text       string `json:"text"`
	SourceLang string `json:"sourceLang"`
	TargetLang string `json:"targetLang"`
}

type GoogleTranslationResponse []interface{}

func translateHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "http://localhost:5173")
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

	source := languageCode(request.SourceLang)
	target := languageCode(request.TargetLang)

	if source == target {
		json.NewEncoder(w).Encode(map[string]string{
			"translation": text,
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

	response, err := http.Get(apiURL + "?" + params.Encode())
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

func languageCode(language string) string {

	codes := map[string]string{

		"English": "en",
		"Tamil":   "ta",
		"Hindi":   "hi",
		"Telugu":  "te",
		"Malayalam": "ml",
		"Kannada":   "kn",
		"Bengali":   "bn",
		"Marathi":   "mr",
		"Gujarati":  "gu",
		"Punjabi":   "pa",
		"Urdu":      "ur",

		"Spanish":    "es",
		"French":     "fr",
		"German":     "de",
		"Italian":    "it",
		"Portuguese": "pt",

		"Japanese": "ja",
		"Korean":   "ko",
		"Chinese":  "zh-CN",

		"Arabic":  "ar",
		"Russian": "ru",
	}

	if code, ok := codes[language]; ok {
		return code
	}

	return "en"
}

func main() {

	http.HandleFunc("/translate", translateHandler)

	fmt.Println("Translation backend running on http://localhost:8080")

	err := http.ListenAndServe(":8080", nil)

	if err != nil {
		panic(err)
	}
}
package com.example.app.web;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
class GreetingController {

    @GetMapping("/api/greeting")
    Greeting greet(@RequestParam(defaultValue = "world") String name) {
        return new Greeting("Hello, %s!".formatted(name));
    }

    record Greeting(String message) {}
}

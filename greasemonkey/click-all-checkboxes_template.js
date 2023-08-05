// Original by eviltester.com, commented by ChatGPT
// Copy into web console on a page with checkboxes

// Setting the initial timer value - 100ms
var timer = 100;

// Selecting all checked checkboxes within div elements, assigning to var "checkboxes"
var checkboxes = document.querySelectorAll(
    "div > input[type='checkbox']:checked"
);

// Looping through each item in "checkboxes" - input represented by "checkbox"
checkboxes.forEach((checkbox) => {
    // Run checkbox.click() after setTimeout(timer)??
    setTimeout(function () {
        checkbox.click();
    }, timer);

    // Incrementing the timer value for the next checkbox - 2000ms
    timer += 2000;
});